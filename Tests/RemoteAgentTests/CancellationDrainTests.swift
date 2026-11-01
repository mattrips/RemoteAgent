import Foundation
import Testing
import HarnessCore
import RemoteAgentService

@Suite(.serialized) struct CancellationDrainTests {
    func startWorker(root: URL, acknowledgesCancellation: Bool = true) async throws -> WorkerBridge {
        let script = root.appendingPathComponent("worker.py")
        let source = #"""
import json,sys,time
def send(x): print(json.dumps(x),flush=True)
send(dict(version=1,requestID='00000000-0000-0000-0000-000000000000',kind='result',terminal=True,model=dict(identity='FAKE',directory='',contextCapacity=131072,temperature=.6)))
pending=None
for line in sys.stdin:
 r=json.loads(line)
 if r['operation']=='cache.prefill':
  pending=r['id'];send(dict(version=1,requestID=pending,kind='progress',terminal=False));continue
 if r['operation']=='cancel':
  open(sys.argv[0]+'.cancelling','w').close()
  if ACK:
   time.sleep(.4)
   send(dict(version=1,requestID=pending,kind='error',terminal=True,errorCode='cancelled'))
   pending=None
  continue
 send(dict(version=1,requestID=r['id'],kind='result',terminal=True,text='Next request completed'))
"""#.replacingOccurrences(of: "ACK", with: acknowledgesCancellation ? "True" : "False")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let worker = WorkerBridge()
        try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
        for _ in 0..<200 {
            if await worker.configuration != nil { return worker }
            try await Task.sleep(for: .milliseconds(10))
        }
        await worker.stop()
        throw HarnessError.state("Fake worker did not become ready")
    }
    @Test func disconnectedPrefillKeepsTheGateUntilCancellationAcknowledgment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = try await startWorker(root: root)
        let port = Int.random(in: 49152...65535), key = String(repeating: "d", count: 44)
        let server = HTTPServer(worker: worker, secret: key, journalDirectory: root.appendingPathComponent("journal"))
        try await server.start(port: port)
        @Sendable func rpc(_ request: RemoteAgentRequest) async throws -> [RemoteAgentEvent] {
            var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
            http.httpMethod = "POST"; http.httpBody = try JSONEncoder().encode(request)
            http.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await URLSession.shared.data(for: http)
            return try data.split(separator: 10).map { try JSONDecoder().decode(RemoteAgentEvent.self, from: Data($0)) }
        }
        do {
            let prefill = RemoteAgentRequest("cache.prefill")
            let disconnected = Task { try await rpc(prefill) }
            for _ in 0..<200 { if await worker.hasPending(prefill.id) { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(await worker.hasPending(prefill.id))
            disconnected.cancel(); _ = await disconnected.result
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("worker.py.cancelling").path) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("worker.py.cancelling").path))
            #expect(await worker.hasPending(prefill.id))
            let next = Task { try await rpc(.init("generate")) }
            for _ in 0..<100 { if await server.queueCount() == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
            #expect(await server.queueCount() == 1)
            let result = try await next.value
            #expect(result.last?.kind == "result" && result.last?.text == "Next request completed")
            #expect(!result.contains { $0.kind == "error" })
            await server.stop(); await worker.stop()
        } catch { await worker.stop(); await server.stop(); throw error }
    }
    @Test func cancelledDrainWaitersWaitForIsolationOfAnUnresponsiveWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = try await startWorker(root: root, acknowledgesCancellation: false)
        let request = RemoteAgentRequest("cache.prefill")
        let stream = try await worker.stream(request)
        let consumer = Task { for try await _ in stream { } }
        let first = Task { await worker.cancelAndDrain(request.id) }
        let second = Task { await worker.cancelAndDrain(request.id) }
        first.cancel() // Cancellation of the caller must not release the slot early.
        await first.value; await second.value
        #expect(await worker.hasPending(request.id) == false)
        #expect(await worker.configuration == nil)
        #expect(await worker.status == "Worker reset after cancellation; reload model")
        _ = await consumer.result
        await worker.stop()
    }
}
