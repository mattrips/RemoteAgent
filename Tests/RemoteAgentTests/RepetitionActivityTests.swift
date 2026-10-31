import Foundation
import Testing
import HarnessCore
@testable import RemoteAgentService

struct RepetitionActivityTests {
    @Test func stoppedLoopLeavesWorkerAvailableForTheNextRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker.py")
        try #"""
import json,sys
def send(x):print(json.dumps(x),flush=True)
model=dict(identity='FAKE',directory='',contextCapacity=131072,temperature=.6)
send(dict(version=1,requestID='00000000-0000-0000-0000-000000000000',kind='result',terminal=True,model=model))
for line in sys.stdin:
 r=json.loads(line);base=dict(version=1,requestID=r['id'])
 if r['operation']=='generate':
  usage=dict(inputTokens=9000,outputTokens=192)
  send(dict(base,kind='usage',terminal=False,text='repetitionDetected',usage=usage))
  send(dict(base,kind='error',terminal=True,errorCode='repetition_detected',text='Repetition detected',usage=usage,repetition=dict(patternTokens=16,repetitions=12,startGeneratedToken=0)))
 else:send(dict(base,kind='result',terminal=True,model=model,cacheCount=1,sessionCount=1))
"""#.write(to: script, atomically: true, encoding: .utf8)
        let worker = WorkerBridge()
        try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
        do {
            for _ in 0..<1000 { if await worker.configuration != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(await worker.configuration != nil)
            var failure: RemoteAgentEvent?
            for try await event in try await worker.stream(.init("generate")) { if event.terminal { failure = event } }
            #expect(failure?.errorCode == RepetitionDetectionError.code)
            #expect(await worker.lastRequestOutcome == "Repetition detected")
            #expect(await worker.configuration != nil)
            var next: RemoteAgentEvent?
            for try await event in try await worker.stream(.init("status")) { if event.terminal { next = event } }
            #expect(next?.cacheCount == 1 && next?.sessionCount == 1)
            await worker.stop()
        } catch { await worker.stop(); throw error }
    }
    @Test func repetitionHasDistinctOutcomeAndCountsWithoutOutputInLog() throws {
        var log = RemoteActivityLog()
        let request = RemoteAgentRequest("generate")
        log.begin(request, client: "Client", running: true)
        var error = RemoteAgentEvent.failure(request.id, code: RepetitionDetectionError.code, message: "PRIVATE LOOP TEXT")
        error.repetition = .init(patternTokens: 16, repetitions: 12, startGeneratedToken: 10)
        error.usage = .init(inputTokens: 9000, outputTokens: 202)
        log.finish(error)
        #expect(log.records.first?.status == "Repetition detected")
        #expect(log.records.first?.generatedTokens == 202)
        #expect(log.records.last?.detail.contains("16-token block") == true)
        #expect(!String(describing: log.records).contains("PRIVATE"))
    }
}
