import Foundation
import Testing
import RemoteAgentService
import HarnessCore

@Suite(.serialized) struct ServiceTests {
    @Test func authAndProtocolLimitsAreExplicit() throws {
        let key = String(repeating: "a", count: 44)
        #expect(HTTPServer.authorized("Bearer " + key, secret: key))
        #expect(!HTTPServer.authorized("Bearer " + key + "x", secret: key))
        #expect(!HTTPServer.authorized(nil, secret: key))
        var request = RemoteAgentRequest("generate"); request.temperature = .nan
        #expect(throws: Error.self) { try request.validate() }
        request.temperature = 0.6; request.tokens = [-1]
        #expect(throws: Error.self) { try request.validate() }
        request.tokens = Array(repeating: 1, count: 131073)
        #expect(throws: Error.self) { try request.validate() }
        #expect(RemoteAgentLimits.allocationBudget(physicalBytes: 512 << 30) == 448 << 30)
    }
    @Test func queuedCancellationDoesNotLoseTheNextClient() async throws {
        let gate = JobGate(); try await gate.acquire(UUID())
        let queued = Task { try await gate.acquire(UUID()) }
        try await Task.sleep(for: .milliseconds(50)); queued.cancel()
        await #expect(throws: Error.self) { try await queued.value }
        await gate.release(); try await gate.acquire(UUID()); await gate.release()
    }
    @Test func replacingAnInstanceCancelsOnlyItsQueuedSessions() async throws {
        let gate = JobGate(), old = UUID(), other = UUID()
        try await gate.acquire(UUID())
        let first = Task { try await gate.acquire(UUID(), sessionID: old, operation: "generate") }
        let second = Task { try await gate.acquire(UUID(), sessionID: other, operation: "generate") }
        for _ in 0..<100 { if await gate.count() == 2 { break }; try await Task.sleep(for: .milliseconds(2)) }
        await gate.cancelQueuedSessions([old])
        await #expect(throws: Error.self) { try await first.value }
        #expect(await gate.queuedSessions()[other] == 1)
        await gate.release(); try await second.value; await gate.release()
    }
    @Test func loopbackHTTPRejectsUnauthorizedAndMalformedRequests() async throws {
        let worker = WorkerBridge(), key = String(repeating: "q", count: 44), service = HTTPServer(worker: worker, secret: key)
        // Avoid a fixed port left in TIME_WAIT by another test/build run.
        let port = Int.random(in: 49152...65535)
        try await service.start(port: port)
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, denied) = try await URLSession.shared.data(for: request)
            #expect((denied as? HTTPURLResponse)?.statusCode == 401)
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            let (_, malformed) = try await URLSession.shared.data(for: request)
            #expect((malformed as? HTTPURLResponse)?.statusCode == 400)
            await service.stop()
        } catch { await service.stop(); throw error }
    }
    @Test func isolatedWorkerFailureIsReportedAndParentCanStartAnotherWorker() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker.py")
        try Data(#"""
import sys,json,os,uuid,time
def send(x): print(json.dumps(x),flush=True)
send({'version':1,'requestID':'00000000-0000-0000-0000-000000000000','kind':'result','terminal':True,'model':{'identity':'TEST-NOT-A-REAL-MODEL','directory':'','contextCapacity':131072,'temperature':0.6}})
waiting=None
for line in sys.stdin:
 r=json.loads(line)
 if r.get('text')=='crash': os._exit(71)
 if r.get('text')=='wait':
  waiting=r['id'];send({'version':1,'requestID':waiting,'kind':'progress','terminal':False,'generatedTokens':1});continue
 if r['operation']=='cancel':
  time.sleep(.05)
  send({'version':1,'requestID':waiting,'kind':'error','errorCode':'cancelled','terminal':True});waiting=None;continue
 send({'version':1,'requestID':r['id'],'kind':'result','terminal':True,'sessionID':str(uuid.uuid4())})
"""#.utf8).write(to: script)
        let worker = WorkerBridge()
        func start() async throws {
            try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
            for _ in 0..<100 { if await worker.configuration != nil { return }; try await Task.sleep(for: .milliseconds(50)) }
            throw HarnessError.state("Fake worker did not become ready")
        }
        try await start()
        #expect(await worker.startupInProgress == false)
        var request = RemoteAgentRequest("session.create")
        var succeeded = false
        for try await event in try await worker.stream(request) { succeeded = event.terminal }
        #expect(succeeded)
        request = .init("generate"); request.text = "wait"
        let waitingID = request.id
        let stream = try await worker.stream(request)
        let consumer = Task { for try await _ in stream { } }
        #expect(await worker.requestStartedAt != nil)
        await worker.cancel(waitingID)
        _ = await consumer.result
        for _ in 0..<100 {
            if await worker.requestStartedAt == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await worker.requestStartedAt == nil)
        #expect(await worker.lastRequestOutcome == "Cancelled")
        // Metadata queries must not erase the cancellation indication.
        for try await _ in try await worker.stream(.init("status")) { }
        #expect(await worker.lastRequestOutcome == "Cancelled")
        request = .init("generate"); request.text = "next"
        for try await _ in try await worker.stream(request) { }
        #expect(await worker.lastRequestOutcome == nil)
        request = .init("generate"); request.text = "crash"
        await #expect(throws: Error.self) { for try await _ in try await worker.stream(request) { } }
        #expect(await worker.configuration == nil)
        try await start()
        #expect(await worker.configuration?.identity == "TEST-NOT-A-REAL-MODEL")
        await worker.stop()
    }
}
