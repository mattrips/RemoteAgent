import Foundation
import Testing
@testable import RemoteAgentService

struct StartupReadinessTests {
    @Test func failedModelInitializationIsNotMistakenForPendingStartup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StartupWorker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker.py")
        try Data("import json,time\ntime.sleep(.1)\nprint(json.dumps({'version':1,'requestID':'00000000-0000-0000-0000-000000000000','kind':'error','errorCode':'load_failed','text':'Fixture load failure','terminal':True}),flush=True)\ninput()\n".utf8).write(to: script)
        let worker = WorkerBridge()
        try await worker.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), model: script)
        #expect(await worker.startupInProgress)
        for _ in 0..<200 {
            if await worker.status == "Fixture load failure" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await worker.configuration == nil)
        #expect(await worker.status == "Fixture load failure")
        #expect(await !worker.startupInProgress)
        await worker.stop()
    }
}
