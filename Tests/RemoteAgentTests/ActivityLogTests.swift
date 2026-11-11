import Foundation
import Testing
import HarnessCore
@testable import RemoteAgentService

struct ActivityLogTests {
    @Test func requestIdentityUsesDeviceMetadataAndSessionFallback() {
        let session = RemoteSessionInfo(id: UUID(), clientName: "Decomposer", deviceName: "Office Mac")
        var request = RemoteAgentRequest("generate")
        request.sessionID = session.id
        #expect(RemoteActivityLog.clientLabel(for: request, sessions: [session]) == "Decomposer · Office Mac")
        request.clientName = "Ray"
        #expect(RemoteActivityLog.clientLabel(for: request, sessions: [session]) == "Ray · Office Mac")
        request.deviceName = "Laptop"
        #expect(RemoteActivityLog.clientLabel(for: request, sessions: [session]) == "Ray · Laptop")
        request.clientName = " "; request.deviceName = " "
        #expect(RemoteActivityLog.clientLabel(for: request, sessions: [session]) == "Decomposer · Office Mac")
        request.sessionID = UUID()
        #expect(RemoteActivityLog.clientLabel(for: request, sessions: [session]) == "Unknown client")
        #expect(RemoteActivityLog.clientLabel(clientName: "Ray\n", deviceName: "Mac\u{0000}") == "Ray · Mac")
    }
    @Test func longNamesRetainDeviceAndSessionConnectionsUseSameLabel() throws {
        let name = String(repeating: "A", count: 120)
        let session = RemoteSessionInfo(id: UUID(), clientName: name, deviceName: "Office Mac")
        var log = RemoteActivityLog()
        log.sessionsChanged(from: [], to: [session])
        log.sessionsChanged(from: [session], to: [])
        #expect(log.records.map(\.client) == [name + " · Office Mac", name + " · Office Mac"])
    }
    @Test func bridgeFailuresAndTransportDropsRetainRequestComputer() async throws {
        let bridge = WorkerBridge()
        var request = RemoteAgentRequest("generate")
        request.clientName = "Decomposer"; request.deviceName = "Office Mac"; request.sessionID = UUID()
        await bridge.recordQueuedRequest(request)
        await bridge.recordRequestFailure(request, code: "busy")
        await bridge.recordTransportDrop(request.id)
        let rows = await bridge.activityRecords
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.client == "Decomposer · Office Mac" && $0.sessionID == request.sessionID })
    }
    @Test func requestLifecycleRetainsOnlyMetadataAndDeduplicatesErrors() throws {
        var log = RemoteActivityLog(), request = RemoteAgentRequest("generate")
        request.tokens = [9901, 9902]; request.clientName = "Client"
        log.begin(request, client: "Client", running: false)
        log.begin(request, client: "Client", running: true)
        var progress = RemoteAgentEvent("progress", requestID: request.id)
        progress.text = "PRIVATE OUTPUT MUST NOT BE LOGGED"; progress.generatedTokens = 42
        log.finish(progress)
        let failure = RemoteAgentEvent.failure(request.id, code: "memory_pressure", message: "PRIVATE ERROR MUST NOT BE LOGGED")
        log.finish(failure); log.finish(failure)
        let row = try #require(log.records.first)
        #expect(row.status == "Failed" && row.inputTokens == 2 && row.generatedTokens == 42)
        #expect(log.records.count == 2)
        #expect(!String(describing: log.records).contains("PRIVATE"))
        log.clear(); #expect(log.records.isEmpty)
    }
    @Test func retentionAndClearPreserveActiveRequestsAndPollingIsOmitted() {
        var log = RemoteActivityLog(), request = RemoteAgentRequest("generate")
        log.begin(request, client: "Active", running: true)
        for _ in 0..<1100 { log.add(category: "Service", operation: "worker", status: "Ready") }
        #expect(log.records.count == 1000 && log.tracks(request.id))
        log.clear(); #expect(log.records.count == 1)
        request = RemoteAgentRequest("status"); log.begin(request, client: "Poll", running: true)
        #expect(log.records.count == 1)
    }
    @Test func sessionChangesAreLogicalConnectionsAndCancellationIsExplicit() throws {
        var log = RemoteActivityLog()
        let session = RemoteSessionInfo(id: UUID(), clientName: "Decomposer", deviceName: "Mac")
        log.sessionsChanged(from: [], to: [session]); log.sessionsChanged(from: [session], to: [session])
        log.sessionsChanged(from: [session], to: [])
        #expect(log.records.map(\.status) == ["Connected", "Disconnected"])
        let request = RemoteAgentRequest("generate")
        log.begin(request, client: "Decomposer", running: true)
        log.finish(.failure(request.id, code: "cancelled", message: ""))
        #expect(log.records.last?.status == "Cancelled")
        #expect(!log.records.contains { $0.category == "Error" })
    }
}
