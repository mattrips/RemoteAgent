import Foundation
import CryptoKit
import NIOCore
import NIOPosix
import NIOHTTP1
import HarnessCore
import ServiceKit

public actor JobGate {
    private var active = false
    private var waiters: [(UUID, UUID?, String, CheckedContinuation<Void, Error>)] = []
    public init() {}
    public func acquire(_ id: UUID, sessionID: UUID? = nil, operation: String = "unknown") async throws {
        try Task.checkCancellation()
        if !active { active = true; return }
        guard waiters.count < 4 else { throw HarnessError.state("busy: request queue is full; retry later") }
        try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { waiters.append((id, sessionID, operation, $0)) } } onCancel: { Task { await self.remove(id) } }
    }
    private func remove(_ id: UUID) { if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).3.resume(throwing: CancellationError()) } }
    public func tryAcquire() -> Bool { guard !active else { return false }; active = true; return true }
    public func release() { if waiters.isEmpty { active = false } else { waiters.removeFirst().3.resume() } }
    public func queuedSessions() -> [UUID: Int] { Dictionary(grouping: waiters.compactMap { $0.1 }, by: { $0 }).mapValues(\.count) }
    public func cancelQueuedSessions(_ sessions: Set<UUID>) {
        let removed = waiters.filter { $0.1.map { sessions.contains($0) } == true }
        waiters.removeAll { $0.1.map { sessions.contains($0) } == true }
        for item in removed { item.3.resume(throwing: CancellationError()) }
    }
    public func count() -> Int { waiters.count }
}

public final class HTTPServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: Channel?
    private var maintenance: Task<Void, Never>?
    private let worker: WorkerBridge
    private let secret: String
    private let gate: JobGate
    private let coordinator: RequestCoordinator
    public let backgroundDirectory: URL
    public init(worker: WorkerBridge, secret: String, backgroundDirectory: URL = BackgroundPublication.defaultDirectory, journalDirectory: URL? = nil) {
        self.worker = worker; self.secret = secret; self.backgroundDirectory = backgroundDirectory
        let gate = JobGate(); self.gate = gate
        coordinator = RequestCoordinator(worker: worker, gate: gate, journal: RequestJournal(directory: journalDirectory ?? RequestJournal.directory(secret: secret)))
    }
    public func start(port: Int = 8321) async throws {
        guard (1024...65535).contains(port), secret.utf8.count >= 32, channel == nil else { throw HarnessError.invalid("Invalid port, credential or server state") }
        channel = try await LoopbackListener.start(group: group, port: port) { [worker, secret, gate, coordinator, backgroundDirectory] channel in
            channel.pipeline.addHandler(RPCHandler(worker: worker, secret: secret, gate: gate, coordinator: coordinator, backgroundDirectory: backgroundDirectory))
        }
        maintenance = Task { [coordinator] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)); try await coordinator.journal.expireCompletedRecords() }
                catch { if Task.isCancelled { return } }
            }
        }
    }
    public func stop() async { maintenance?.cancel(); maintenance = nil; await coordinator.shutdown(); try? await channel?.close().get(); channel = nil; try? await group.shutdownGracefully() }
    public func queuedSessions() async -> [UUID: Int] { await gate.queuedSessions() }
    public func refreshSessionsIfIdle() async {
        guard await gate.tryAcquire() else { return }
        do { for try await _ in try await worker.stream(.init("status")) { } } catch { }
        await gate.release()
    }
    public func closeIdleSession(_ id: UUID) async throws {
        let ticket = UUID()
        try await gate.acquire(ticket)
        do {
            guard await gate.queuedSessions()[id] == nil else { throw HarnessError.state("This session has queued work; cancel it before closing the session") }
            var request = RemoteAgentRequest("session.close"); request.sessionID = id
            for try await event in try await worker.stream(request) {
                if event.kind == "error" { throw HarnessError.state(event.text ?? "Could not close session") }
            }
            await gate.release()
        } catch { await gate.release(); throw error }
    }
    public func queueCount() async -> Int { await gate.count() }
    public static func authorized(_ header: String?, secret: String) -> Bool { ServiceCredentials.authorized(header, secret: secret) }
}

private final class RPCHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let worker: WorkerBridge, secret: String, gate: JobGate
    private var body = Data(), rejected = false, started = false, completed = false
    private var task: Task<Void, Never>?
    private let coordinator: RequestCoordinator
    private let backgroundDirectory: URL
    private var userAgent: String?
    private var acceptedRequestID: UUID?
    private static let connectionLock = NSLock()
    private static var connections = 0
    private var counted = false
    init(worker: WorkerBridge, secret: String, gate: JobGate, coordinator: RequestCoordinator, backgroundDirectory: URL) { self.worker = worker; self.secret = secret; self.gate = gate; self.coordinator = coordinator; self.backgroundDirectory = backgroundDirectory }
    func handlerAdded(context: ChannelHandlerContext) {
        Self.connectionLock.lock()
        if Self.connections < 32 { Self.connections += 1; counted = true }
        Self.connectionLock.unlock()
        guard counted else { context.close(promise: nil); return }
        context.eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in if self?.started == false { context.close(promise: nil) } }
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        if counted { Self.connectionLock.lock(); Self.connections -= 1; Self.connectionLock.unlock(); counted = false }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard !started else { rejected = true; context.close(promise: nil); return }
            if head.method != .POST || head.uri != "/v1/rpc" { reject(context, .notFound); return }
            guard head.headers["authorization"].count == 1, HTTPServer.authorized(head.headers.first(name: "authorization"), secret: secret) else { reject(context, .unauthorized); return }
            guard head.headers.first(name: "content-type")?.hasPrefix("application/json") == true else { reject(context, .unsupportedMediaType); return }
            userAgent = head.headers.first(name: "user-agent").map { String($0.prefix(120)) }
            if let length = head.headers.first(name: "content-length"), (Int(length) ?? Int.max) > 4_000_000 { reject(context, .payloadTooLarge); return }
            context.eventLoop.scheduleTask(in: .seconds(30)) { [weak self] in if self?.started == false { context.close(promise: nil) } }
        case .body(var bytes):
            guard !rejected, !started, body.count + bytes.readableBytes <= 4_000_000 else { reject(context, .payloadTooLarge); return }
            body.append(contentsOf: bytes.readBytes(length: bytes.readableBytes) ?? [])
        case .end:
            guard !rejected, !started else { return }; started = true
            var request: RemoteAgentRequest
            do { request = try JSONDecoder().decode(RemoteAgentRequest.self, from: body); try request.validate() }
            catch { reject(context, .badRequest); return }
            if request.operation == "session.create", request.clientName == nil { request.clientName = userAgent?.components(separatedBy: " " ).first ?? "Unlabelled client" }
            acceptedRequestID = request.id
            body.removeAll(keepingCapacity: false)
            let channel = context.channel
            var headers = HTTPHeaders(); headers.add(name: "content-type", value: "application/x-ndjson"); headers.add(name: "cache-control", value: "no-store"); headers.add(name: "connection", value: "close"); headers.add(name: "x-content-type-options", value: "nosniff")
            channel.writeAndFlush(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: headers)), promise: nil)
            task = Task { [worker, gate, coordinator, backgroundDirectory] in
                let heartbeat = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { var event = RemoteAgentEvent("heartbeat", requestID: request.id); event.text = "Waiting or processing"; self.send(event, channel: channel) } } }
                defer { heartbeat.cancel() }
                do {
                    switch request.operation {
                    case "capabilities":
                        var event = RemoteAgentEvent("capabilities", requestID: request.id); event.capabilities = .init(); event.terminal = true; self.send(event, channel: channel)
                    case "background.get":
                        let snapshot = try BackgroundPublication.read(directory: backgroundDirectory)
                        var event = RemoteAgentEvent("background", requestID: request.id)
                        event.notModified = request.fingerprint == snapshot.id
                        if event.notModified != true { event.background = snapshot }
                        event.terminal = true; self.send(event, channel: channel)
                    case "request.status", "request.replay":
                        guard let id = request.targetID else { throw HarnessError.invalid("targetID is required") }
                        var event = RemoteAgentEvent("requestStatus", requestID: request.id)
                        event.requestStatus = try await coordinator.journal.status(id)
                        if request.operation == "request.replay" { event.replayEvents = try await coordinator.journal.replay(id, after: request.afterSequence ?? 0, limit: request.limit ?? 1000) }
                        event.terminal = true; self.send(event, channel: channel)
                    case "cancel":
                        if let id = request.targetID { await coordinator.cancel(id) }
                        var event = RemoteAgentEvent("cancellationAccepted", requestID: request.id)
                        event.text = "Cancellation requested; inspect the original request for its terminal outcome"
                        event.terminal = true; self.send(event, channel: channel)
                    case "generate":
                        await coordinator.run(request) { event in self.send(event, channel: channel) }
                    default:
                        var queued = RemoteAgentEvent("requestState", requestID: request.id); queued.text = "queued"; self.send(queued, channel: channel)
                        try await gate.acquire(request.id, sessionID: request.sessionID, operation: request.operation)
                        do {
                            try Task.checkCancellation()
                            var running = RemoteAgentEvent("requestState", requestID: request.id); running.text = "running"; self.send(running, channel: channel)
                            var workerRequest = request
                            if request.operation == "session.create" {
                                let old = RemoteSessionPolicy.superseded(await worker.sessions, clientName: request.clientName, deviceName: request.deviceName, instance: request.clientInstanceID, deviceID: request.clientDeviceID)
                                await gate.cancelQueuedSessions(Set(old))
                            }
                            workerRequest.protectedSessionIDs = Array(await gate.queuedSessions().keys)
                            let stream = try await worker.stream(workerRequest)
                            for try await event in stream { try Task.checkCancellation(); self.send(event, channel: channel) }
                            await gate.release()
                        } catch { await gate.release(); throw error }
                    }
                } catch { await worker.recordRequestFailure(request, code: "service_failed"); self.send(.failure(request.id, code: "service_failed", message: error.localizedDescription, retryable: false), channel: channel) }
                channel.eventLoop.execute { self.completed = true; channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) } }
            }
        }
    }
    private func send(_ event: RemoteAgentEvent, channel: Channel) {
        guard let bytes = try? JSONEncoder().encode(event), bytes.count <= RemoteAgentLimits.maxFrameBytes else {
            if event.kind != "error" { send(.failure(event.requestID, code: "frame_too_large", message: "Response exceeded frame limit; use a smaller replay limit"), channel: channel) }; return
        }
        channel.eventLoop.execute {
            guard channel.isActive, channel.isWritable else { self.task?.cancel(); channel.close(promise: nil); return }
            var buffer = channel.allocator.buffer(capacity: bytes.count + 1); buffer.writeBytes(bytes); buffer.writeInteger(UInt8(10))
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
    }
    private func reject(_ context: ChannelHandlerContext, _ status: HTTPResponseStatus) {
        guard !rejected else { return }; rejected = true
        let code = "http_" + String(status.code)
        Task { await worker.recordServiceError(code) }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: ["content-length": "0", "connection": "close"]))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { if !completed { task?.cancel(); if let id = acceptedRequestID { Task { await worker.recordTransportDrop(id) } } }; context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { Task { await worker.recordServiceError("transport_error") }; task?.cancel(); context.close(promise: nil) }
}
