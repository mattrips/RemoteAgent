import Foundation
import Testing
import HarnessCore
@testable import RemoteAgentService

@Suite(.serialized) struct PinnedCacheHTTPTests {
    @Test func pinStatusBypassesInferenceAndWarmNeverQueues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker.py")
        try #"""
import json,sys,uuid
def send(x):print(json.dumps(x),flush=True)
epoch=str(uuid.uuid4());pin=None;waiting=None
model=dict(identity='FAKE',directory='',contextCapacity=131072,temperature=.6)
send(dict(version=1,requestID='00000000-0000-0000-0000-000000000000',kind='result',terminal=True,model=model,epoch=epoch))
for line in sys.stdin:
 r=json.loads(line);op=r['operation'];base=dict(version=1,requestID=r['id'])
 if op=='generate':
  waiting=r['id'];send(dict(base,kind='progress',terminal=False,generatedTokens=1));continue
 if op=='cancel':
  send(dict(version=1,requestID=waiting,kind='error',terminal=True,errorCode='cancelled'));waiting=None;continue
 if op=='baseline.ensure':pin=dict(fingerprint=r['fingerprint'],epoch=epoch,tokenCount=9000,bytes=500000000)
 send(dict(base,kind='result',terminal=True,epoch=epoch,pinStateKnown=True,pinnedCache=pin))
"""#.write(to: script, atomically: true, encoding: .utf8)
        let worker = WorkerBridge(), secret = String(repeating: "p", count: 44)
        let server = HTTPServer(worker: worker, secret: secret, journalDirectory: root.appendingPathComponent("journal"))
        let port = Int.random(in: 49152...65535)
        func call(_ rpc: RemoteAgentRequest) async throws -> RemoteAgentEvent {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(rpc)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let events = try data.split(separator: 10).map { try JSONDecoder().decode(RemoteAgentEvent.self, from: Data($0)) }
            return try #require(events.last(where: { $0.terminal }))
        }
        try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
        do {
            for _ in 0..<1000 { if await worker.configuration != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            try await server.start(port: port)
            var warm = RemoteAgentRequest("baseline.ensure"); warm.messages = [.init(.system, "Background")]; warm.fingerprint = "test-fingerprint"
            let ready = try await call(warm)
            #expect(ready.pinnedCache?.tokenCount == 9000)
            var generate = RemoteAgentRequest("generate"); generate.tokens = [1, 2]
            let active = generate
            let pending = Task { try await call(active) }
            for _ in 0..<1000 { if await worker.requestStartedAt != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(await worker.requestStartedAt != nil)
            let status = try await call(.init("baseline.status"))
            #expect(status.pinnedCache == ready.pinnedCache)
            warm.id = UUID()
            let deferred = try await call(warm)
            #expect(deferred.text == "deferred")
            #expect(await server.queueCount() == 0)
            for operation in ["configuration", "session.create", "tokenize", "cache.inspect", "cache.prefill"] {
                var prepare = RemoteAgentRequest(operation); prepare.opportunistic = true
                let deferredPreparation = try await call(prepare)
                #expect(deferredPreparation.text == "deferred")
                #expect(await server.queueCount() == 0)
            }
            var invalid = RemoteAgentRequest("generate"); invalid.opportunistic = true
            #expect(throws: (any Error).self) { try invalid.validate() }
            var countOnly = RemoteAgentRequest("tokenize"); countOnly.countOnly = true
            try countOnly.validate()
            countOnly.operation = "generate"
            #expect(throws: (any Error).self) { try countOnly.validate() }
            var cancel = RemoteAgentRequest("cancel"); cancel.targetID = active.id
            _ = try await call(cancel); _ = try await pending.value
            var close = RemoteAgentRequest("session.close"); close.sessionID = UUID()
            _ = try await call(close)
            #expect(await worker.pinnedCache == ready.pinnedCache)
            await worker.stop()
            #expect(await worker.pinnedCache == nil)
            let unloaded = try await call(.init("baseline.status"))
            #expect(unloaded.pinnedCache == nil && unloaded.epoch == nil)
            await server.stop()
        } catch { await worker.stop(); await server.stop(); throw error }
    }
}
