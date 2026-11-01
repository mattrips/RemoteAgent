import Foundation
import HarnessCore

/// Owns requests independently of an individual HTTP connection. The bounded
/// output journal lets a client inspect/replay rather than blindly resubmit.
public actor RequestCoordinator {
    private let worker: WorkerBridge
    private let gate: JobGate
    public let journal: RequestJournal
    private var jobs: [UUID: Task<Void, Never>] = [:]
    public init(worker: WorkerBridge, gate: JobGate, journal: RequestJournal) { self.worker = worker; self.gate = gate; self.journal = journal }
    public func run(_ request: RemoteAgentRequest, emit: @escaping @Sendable (RemoteAgentEvent) -> Void) async {
        do {
            guard try await journal.begin(request) else {
                var event = RemoteAgentEvent("requestStatus", requestID: request.id)
                event.requestStatus = try await journal.status(request.id); event.terminal = true; emit(event); return
            }
            await worker.recordQueuedRequest(request)
            let task = Task { [worker, gate, journal] in
                var acquired = false
                do {
                    var queued = RemoteAgentEvent("requestState", requestID: request.id); queued.text = "queued"
                    emit(try await journal.append(queued))
                    try await gate.acquire(request.id, sessionID: request.sessionID, operation: request.operation)
                    acquired = true; try Task.checkCancellation()
                    var running = RemoteAgentEvent("requestState", requestID: request.id); running.text = "running"
                    emit(try await journal.append(running))
                    var workerRequest = request
                    workerRequest.protectedSessionIDs = Array(await gate.queuedSessions().keys)
                    try Task.checkCancellation()
                    let stream = try await worker.stream(workerRequest)
                    for try await event in stream {
                        try Task.checkCancellation()
                        emit(try await journal.append(event))
                    }
                    await worker.cancelAndDrain(request.id)
                    await gate.release()
                } catch {
                    if acquired { await worker.cancelAndDrain(request.id); await gate.release() }
                    let cancellation = error is CancellationError || error.localizedDescription.lowercased().contains("cancelled")
                    await worker.recordRequestFailure(request, code: cancellation ? "cancelled" : "service_failed")
                    let failure = RemoteAgentEvent.failure(request.id, code: cancellation ? "cancelled" : "service_failed", message: error.localizedDescription)
                    do { emit(try await journal.append(failure)) }
                    catch {
                        await journal.markStorageFailure(request.id)
                        emit(.failure(request.id, code: "journal_failed", message: "Recovery storage failed. Partial output may be available through request.status/replay. " + error.localizedDescription))
                    }
                }
            }
            jobs[request.id] = task
            await task.value
            jobs.removeValue(forKey: request.id)
        } catch { await worker.recordServiceError("request_rejected"); emit(.failure(request.id, code: "request_rejected", message: error.localizedDescription)) }
    }
    public func cancel(_ id: UUID) async {
        // Cancel queue wait immediately. Active cancellation is completed by
        // the worker's terminal stream, or its isolation watchdog.
        if await worker.hasPending(id) { await worker.cancel(id) }
        else { jobs[id]?.cancel() }
    }
    public func shutdown() async {
        let pending = jobs
        for id in pending.keys { await cancel(id) }
        for task in pending.values { await task.value }
    }
}
