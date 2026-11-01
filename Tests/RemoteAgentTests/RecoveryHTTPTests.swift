import Foundation
import Testing
import HarnessCore
import RemoteAgentService

@Suite(.serialized) struct RecoveryHTTPTests {
    @Test func queuedCancellationNeverRunsAndActiveCancellationWaitsForWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("cancel.py")
        try #"""
import json,sys,time
def send(x): print(json.dumps(x),flush=True)
send(dict(version=1,requestID='00000000-0000-0000-0000-000000000000',kind='result',terminal=True,model=dict(identity='FAKE',directory='',contextCapacity=131072,temperature=.6)))
pending=None
for line in sys.stdin:
 r=json.loads(line)
 if r['operation']=='generate':
  with open(sys.argv[0]+'.count','a') as f:f.write('run\n')
  pending=r['id'];send(dict(version=1,requestID=pending,kind='progress',terminal=False));continue
 if r['operation']=='cancel' and pending:
  time.sleep(.1);send(dict(version=1,requestID=pending,kind='error',terminal=True,errorCode='cancelled',text='Worker confirmed cancellation'));pending=None
"""#.write(to: script, atomically: true, encoding: .utf8)
        let worker = WorkerBridge()
        try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
        for _ in 0..<100 { if await worker.configuration != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let key = String(repeating: "q", count: 44), port = Int.random(in: 49152...65535)
        let server = HTTPServer(worker: worker, secret: key, journalDirectory: root.appendingPathComponent("journal"))
        try await server.start(port: port)
        @Sendable func rpc(_ request: RemoteAgentRequest) async throws -> [RemoteAgentEvent] {
            var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
            http.httpMethod = "POST"; http.httpBody = try JSONEncoder().encode(request)
            http.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await URLSession.shared.data(for: http)
            return try data.split(separator: 10).map { try JSONDecoder().decode(RemoteAgentEvent.self, from: Data($0)) }
        }
        do {
            let active = RemoteAgentRequest("generate"), queued = RemoteAgentRequest("generate")
            let first = Task { try await rpc(active) }
            for _ in 0..<100 { if await worker.hasPending(active.id) { break }; try await Task.sleep(for: .milliseconds(10)) }
            let sampledAfter = Date()
            let thermalProbe = try await rpc(.init("capabilities"))
            let thermal = try #require(thermalProbe.last?.capabilities?.hostThermal)
            #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(thermal.state))
            #expect(thermal.sampledAt >= sampledAfter && thermal.sampledAt <= Date())
            #expect(thermalProbe.last?.terminal == true)
            #expect(await server.queueCount() == 0)
            #expect(await worker.hasPending(active.id))
            let second = Task { try await rpc(queued) }
            for _ in 0..<100 { if await server.queueCount() == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
            var cancel = RemoteAgentRequest("cancel"); cancel.targetID = queued.id
            #expect(try await rpc(cancel).last?.kind == "cancellationAccepted")
            #expect(try await second.value.last?.errorCode == "cancelled")
            cancel = .init("cancel"); cancel.targetID = active.id
            #expect(try await rpc(cancel).last?.kind == "cancellationAccepted")
            #expect(try await first.value.last?.text == "Worker confirmed cancellation")
            #expect(try String(contentsOf: URL(fileURLWithPath: script.path + ".count"), encoding: .utf8) == "run\n")
            await server.stop(); await worker.stop()
        } catch { await worker.stop(); await server.stop(); throw error }
    }
    @Test func generationRunsOnceAndCanBeRecoveredOverHTTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake.py")
        try #"""
import json,sys,os
def send(x): print(json.dumps(x),flush=True)
send(dict(version=1,requestID='00000000-0000-0000-0000-000000000000',kind='result',terminal=True,model=dict(identity='FAKE',directory='',contextCapacity=131072,temperature=.6)))
for line in sys.stdin:
 r=json.loads(line)
 if r['operation']=='cancel': continue
 if r['operation']=='generate':
  with open(sys.argv[0]+'.count','a') as f: f.write('run\n')
  send(dict(version=1,requestID=r['id'],kind='token',terminal=False,text='Answer α',generatedTokens=1))
  send(dict(version=1,requestID=r['id'],kind='usage',terminal=False,usage=dict(inputTokens=10,outputTokens=1)))
 send(dict(version=1,requestID=r['id'],kind='result',terminal=True))
"""#.write(to: script, atomically: true, encoding: .utf8)
        let worker = WorkerBridge()
        try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
        for _ in 0..<100 { if await worker.configuration != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let key = String(repeating: "k", count: 44), port = Int.random(in: 49152...65535)
        let server = HTTPServer(worker: worker, secret: key, backgroundDirectory: root, journalDirectory: root.appendingPathComponent("journal"))
        try await server.start(port: port)
        func rpc(_ request: RemoteAgentRequest) async throws -> [RemoteAgentEvent] {
            var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
            http.httpMethod = "POST"; http.httpBody = try JSONEncoder().encode(request)
            http.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await URLSession.shared.data(for: http)
            return try data.split(separator: 10).map { try JSONDecoder().decode(RemoteAgentEvent.self, from: Data($0)) }
        }
        do {
            let capabilities = try await rpc(.init("capabilities"))
            #expect(capabilities.last?.capabilities?.idempotentGeneration == true)
            var request = RemoteAgentRequest("generate"); request.tokens = [1,2,3]
            let first = try await rpc(request)
            #expect(first.last?.terminal == true && first.contains { $0.text == "Answer α" })
            let duplicate = try await rpc(request)
            #expect(duplicate.last?.requestStatus?.state == "complete")
            #expect(try String(contentsOf: URL(fileURLWithPath: script.path + ".count"), encoding: .utf8) == "run\n")
            var replay = RemoteAgentRequest("request.replay"); replay.targetID = request.id; replay.afterSequence = 0
            let recovered = try await rpc(replay)
            #expect(recovered.last?.replayEvents?.contains { $0.text == "Answer α" } == true)
            #expect(recovered.last?.replayEvents?.last?.terminal == true)
            var changed = request; changed.tokens = [4]
            #expect(try await rpc(changed).last?.kind == "error")
            try "project".write(to: root.appendingPathComponent("Identity.txt"), atomically: true, encoding: .utf8)
            let background = try await rpc(.init("background.get"))
            #expect(background.last?.background?.documents.count == 1)
            var conditional = RemoteAgentRequest("background.get"); conditional.fingerprint = background.last?.background?.id
            #expect(try await rpc(conditional).last?.notModified == true)
            await server.stop(); await worker.stop()
        } catch { await server.stop(); await worker.stop(); throw error }
    }
}
