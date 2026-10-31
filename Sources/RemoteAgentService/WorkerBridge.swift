import Foundation
import HarnessCore
import Darwin

/// Decode-only average measured from streamed tokens, excluding prompt time.
struct LiveDecodeRate {
    private var firstTime: TimeInterval?
    private var firstCount = 0
    private var count = 0
    mutating func record(count: Int, at time: TimeInterval) {
        guard count > 0, count > self.count else { return }
        if firstTime == nil { firstTime = time; firstCount = count }
        self.count = count
    }
    func speed(at time: TimeInterval) -> Double? {
        guard let firstTime, count > firstCount, time - firstTime >= 0.5 else { return nil }
        return Double(count - firstCount) / (time - firstTime)
    }
}

public actor WorkerBridge {
    private var process: Process?
    private var retiringProcess: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var pending: [UUID: AsyncThrowingStream<RemoteAgentEvent, Error>.Continuation] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var cancelling = Set<UUID>()
    private var pendingOperations: [UUID: String] = [:]
    public private(set) var configuration: ModelConfiguration?
    public private(set) var status = "Stopped"
    public private(set) var epoch: UUID?
    public private(set) var activeBytes = 0
    public private(set) var cacheBytes = 0
    public private(set) var cacheCount = 0
    public private(set) var pinnedCache: RemotePinnedCacheInfo?
    public private(set) var sessionCount = 0
    public private(set) var sessions: [RemoteSessionInfo] = []
    public private(set) var activeSessionID: UUID?
    public private(set) var sessionEvents: [String] = []
    public private(set) var inputTokens = 0
    public private(set) var reusedTokens = 0
    public private(set) var generatedTokens = 0
    private var liveDecodeRate = LiveDecodeRate()
    public func liveTokensPerSecond() -> Double? {
        guard requestStartedAt != nil else { return nil }
        return liveDecodeRate.speed(at: ProcessInfo.processInfo.systemUptime)
    }
    public private(set) var prefillCompletedTokens: Int?
    public private(set) var prefillTotalTokens: Int?
    public private(set) var lastUsage: Usage?
    public private(set) var requestStartedAt: Date?
    public private(set) var lastRequestOutcome: String?
    public private(set) var recentErrors: [String] = []
    private var generation = UUID()
    private var activity = RemoteActivityLog()
    public var activityRecords: [RemoteActivityRecord] { activity.records }
    public func clearActivity() { activity.clear() }
    public func recordQueuedRequest(_ request: RemoteAgentRequest) {
        activity.begin(request, client: request.clientName ?? sessions.first(where: { $0.id == request.sessionID })?.clientName ?? "Unknown client", running: false)
    }
    public func recordRequestFailure(_ request: RemoteAgentRequest, code: String) {
        activity.begin(request, client: request.clientName ?? sessions.first(where: { $0.id == request.sessionID })?.clientName ?? "Unknown client", running: false)
        activity.finish(.failure(request.id, code: code, message: ""))
    }
    public func recordServiceError(_ code: String) { activity.add(category: "Error", operation: "service", status: "Failed", errorCode: code) }
    public func recordTransportDrop(_ id: UUID) { activity.add(category: "Connection", client: "HTTP client", operation: "transport", status: "Dropped", requestID: id, detail: "Transport closed before its response completed. Inference may continue; recover using the original request ID.") }
    public init() {}
    public func hasPending(_ id: UUID) -> Bool { pending[id] != nil }
    public func start(executable: URL, model: URL) throws {
        guard process == nil else { throw HarnessError.state("Stop the existing worker before loading another model") }
        guard retiringProcess?.isRunning != true else { throw HarnessError.state("Previous inference worker is still exiting; wait before loading another model") }
        retiringProcess = nil
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable; task.arguments = [model.path]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.standardError
        let ticket = UUID(); generation = ticket; configuration = nil; epoch = nil; buffer = Data(); status = "Loading model…"
        task.terminationHandler = { [weak self] task in Task { await self?.exited(ticket, code: task.terminationStatus, signalled: task.terminationReason == .uncaughtSignal) } }
        do { try task.run() } catch { recordServiceError("worker_launch_failed"); status = "Launch failed: " + error.localizedDescription; throw error }
        activity.add(category: "Service", operation: "model.load", status: "Loading")
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let handle = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
                var bytes = [UInt8](repeating: 0, count: 65536)
                while !Task.isCancelled {
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    // One reader awaits each delivery: independent Tasks can
                    // reorder pipe chunks and corrupt an otherwise valid stream.
                    await self?.received(Data(bytes.prefix(count)), generation: ticket)
                }
        }
        deadlines[UUID(uuidString: "00000000-0000-0000-0000-000000000000")!] = Task { try? await Task.sleep(for: .seconds(600)); if !Task.isCancelled { self.loadingTimedOut(ticket) } }
    }
    public func stop() {
        activity.add(category: "Service", operation: "worker", status: "Stopped")
        status = "Stopped"; generation = UUID()
        if let process, process.isRunning {
            retiringProcess = process; process.terminate()
            Task.detached { try? await Task.sleep(for: .seconds(3)); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        cleanup("Worker stopped. Reload the model and create a fresh session; caches are invalidated.")
    }
    private func cleanup(_ message: String) {
        for id in pending.keys { activity.finish(.failure(id, code: cancelling.contains(id) ? "cancelled" : "worker_unavailable", message: "")) }
        activity.sessionsChanged(from: sessions, to: [])
        reader?.cancel(); reader = nil
        try? input?.close(); try? output?.close(); input = nil; output = nil; process = nil
        configuration = nil; epoch = nil; buffer = Data(); pinnedCache = nil
        activeBytes = 0; cacheBytes = 0; cacheCount = 0; sessionCount = 0; sessions = []; activeSessionID = nil; requestStartedAt = nil
        liveDecodeRate = LiveDecodeRate()
        lastRequestOutcome = nil
        for value in deadlines.values { value.cancel() }; deadlines.removeAll(); cancelling.removeAll()
        for stream in pending.values { stream.finish(throwing: HarnessError.state(message)) }; pending.removeAll(); pendingOperations.removeAll()
    }
    private func exited(_ ticket: UUID, code: Int32, signalled: Bool) {
        guard ticket == generation else { return }
        let name = code == SIGTRAP ? " (SIGTRAP)" : code == SIGKILL ? " (SIGKILL)" : ""
        status = signalled ? "Worker terminated by signal \(code)\(name). Reload model to recover." : "Worker exited with code \(code). Reload model to recover."
        recordServiceError("worker_exited_" + String(code))
        recentErrors.append(status); recentErrors = Array(recentErrors.suffix(20))
        cleanup(status + " No partial output was committed; all cache handles expired.")
    }
    private func loadingTimedOut(_ ticket: UUID) { guard ticket == generation, configuration == nil else { return }; recordServiceError("model_load_timeout"); stop(); status = "Model loading timed out after 10 minutes" }
    private func received(_ data: Data, generation ticket: UUID) {
        guard ticket == generation else { return }
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= RemoteAgentLimits.maxFrameBytes else { recordServiceError("worker_frame_too_large"); stop(); status = "Worker protocol frame exceeded limit"; return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(RemoteAgentEvent.self, from: line), event.version == 1 else { recordServiceError("worker_protocol_invalid"); stop(); status = "Invalid worker protocol; worker isolated and stopped"; return }
            if let value = event.activeBytes { activeBytes = value }
            if let value = event.cacheBytes { cacheBytes = value }
            if let value = event.cacheCount { cacheCount = value }
            if event.pinStateKnown == true { pinnedCache = event.pinnedCache }
            if let value = event.sessionCount { sessionCount = value }
            if let value = event.sessions { activity.sessionsChanged(from: sessions, to: value); sessions = value }
            if let value = event.sessionEvents { sessionEvents = Array((sessionEvents + value).suffix(10)) }
            if event.kind == "progress" || event.terminal { activity.finish(event) }
            if event.kind == "progress" { inputTokens = event.inputTokens ?? inputTokens; reusedTokens = event.reusedTokens ?? reusedTokens }
            if let value = event.generatedTokens { generatedTokens = value }
            if event.kind == "token", let count = event.generatedTokens {
                liveDecodeRate.record(count: count, at: ProcessInfo.processInfo.systemUptime)
            }
            if let value = event.prefillCompletedTokens { prefillCompletedTokens = value }
            if let value = event.prefillTotalTokens { prefillTotalTokens = value }
            if let value = event.usage { lastUsage = value }
            if event.kind == "error", !activity.tracks(event.requestID), event.requestID.uuidString != "00000000-0000-0000-0000-000000000000" {
                activity.add(category: "Error", operation: pendingOperations[event.requestID] ?? "worker", status: "Failed", requestID: event.requestID, sessionID: event.sessionID, errorCode: event.errorCode ?? "worker_error")
            }
            if event.kind == "error" { recentErrors.append(event.text ?? "Worker error"); recentErrors = Array(recentErrors.suffix(20)) }
            if event.requestID.uuidString == "00000000-0000-0000-0000-000000000000" {
                deadlines.removeValue(forKey: event.requestID)?.cancel()
                if event.kind == "error" { status = event.text ?? "Loading failed"; recordServiceError(event.errorCode ?? "model_load_failed") }
                else { configuration = event.model; epoch = event.epoch; status = "Ready"; activity.add(category: "Service", operation: "model.load", status: "Ready") }
            } else if let stream = pending[event.requestID] {
                if case .dropped = stream.yield(event) { stop(); status = "Worker output exceeded bounded delivery buffer; no result committed"; return }
                if event.terminal {
                    let wasCancelling = cancelling.remove(event.requestID) != nil
                    pendingOperations.removeValue(forKey: event.requestID)
                    pending.removeValue(forKey: event.requestID)?.finish(); deadlines.removeValue(forKey: event.requestID)?.cancel(); requestStartedAt = nil; activeSessionID = nil
                    if event.kind == "error" { lastRequestOutcome = event.errorCode == "cancelled" ? "Cancelled" : event.errorCode == RepetitionDetectionError.code ? "Repetition detected" : "Failed" }
                    else if wasCancelling { lastRequestOutcome = "Completed before cancellation" }
                }
            } else if event.terminal, cancelling.remove(event.requestID) != nil {
                deadlines.removeValue(forKey: event.requestID)?.cancel()
                requestStartedAt = nil
                activeSessionID = nil
                liveDecodeRate = LiveDecodeRate()
                lastRequestOutcome = "Cancelled"
            }
        }
    }
    public func stream(_ request: RemoteAgentRequest) throws -> AsyncThrowingStream<RemoteAgentEvent, Error> {
        guard configuration != nil, process?.isRunning == true else { throw HarnessError.state("worker_unavailable: " + status) }
        guard pending.isEmpty, cancelling.isEmpty else { throw HarnessError.state("busy: only one GPU request may run; cancellation may still be draining") }
        activity.begin(request, client: request.clientName ?? sessions.first(where: { $0.id == request.sessionID })?.clientName ?? "Unknown client", running: true)
        let pair = AsyncThrowingStream<RemoteAgentEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        if !["status", "configuration", "session.create", "session.close", "cache.inspect", "cache.release"].contains(request.operation) {
            requestStartedAt = Date(); generatedTokens = 0; prefillCompletedTokens = nil; prefillTotalTokens = nil
            liveDecodeRate = LiveDecodeRate(); activeSessionID = request.sessionID
        }
        if ["generate", "cache.prefill", "cache.append", "cache.fork", "verify"].contains(request.operation) { lastRequestOutcome = nil }
        pending[request.id] = pair.continuation; pendingOperations[request.id] = request.operation
        pair.continuation.onTermination = { [weak self] reason in if case .cancelled = reason { Task { await self?.cancel(request.id) } } }
        do {
            let data = try JSONEncoder().encode(request)
            guard data.count <= RemoteAgentLimits.maxFrameBytes else { throw HarnessError.invalid("Request frame exceeds limit") }
            try input?.write(contentsOf: data + Data([10]))
        } catch {
            pending.removeValue(forKey: request.id)
            pendingOperations.removeValue(forKey: request.id)
            activity.finish(.failure(request.id, code: "request_dispatch_failed", message: ""))
            requestStartedAt = nil; activeSessionID = nil
            throw error
        }
        deadlines[request.id] = Task { try? await Task.sleep(for: .seconds(RemoteAgentLimits.requestTimeout)); if !Task.isCancelled { self.cancel(request.id) } }
        return pair.stream
    }
    public func cancel(_ id: UUID) {
        guard pending[id] != nil, !cancelling.contains(id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        cancelling.insert(id)
        lastRequestOutcome = "Cancelling"
        var cancel = RemoteAgentRequest("cancel"); cancel.targetID = id
        if let data = try? JSONEncoder().encode(cancel) { try? input?.write(contentsOf: data + Data([10])) }
        // Cooperative cancellation cannot interrupt a hung Metal driver. An
        // unresponsive worker is terminated, never used for the next request.
        let ticket = generation
        deadlines[id] = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { self.finishCancellation(ticket) } }
    }
    private func finishCancellation(_ ticket: UUID) { guard ticket == generation else { return }; stop(); status = "Worker reset after cancellation; reload model" }
}
