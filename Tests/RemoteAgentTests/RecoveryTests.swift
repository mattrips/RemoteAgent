import Foundation
import Testing
import RemoteAgentService
import HarnessCore

@Suite(.serialized) struct RecoveryTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func journalIsIdempotentPagedAndDurableWithoutSavingPrompts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = RequestJournal(directory: root)
        var request = RemoteAgentRequest("generate"); request.text = "SECRET-INPUT-NOT-TO-BE-SAVED"
        #expect(try await journal.begin(request))
        #expect(try await !journal.begin(request))
        var changed = request; changed.text = "different"
        await #expect(throws: Error.self) { _ = try await journal.begin(changed) }
        var token = RemoteAgentEvent("token", requestID: request.id); token.text = "Answer α\n"
        let saved = try await journal.append(token); #expect(saved.sequence == 1)
        var done = RemoteAgentEvent("result", requestID: request.id); done.terminal = true
        _ = try await journal.append(done)
        let first = try await journal.replay(request.id, after: 0, limit: 1)
        let second = try await journal.replay(request.id, after: 1, limit: 100)
        #expect(first.count == 1 && second.count == 1 && second[0].terminal)
        let reopened = RequestJournal(directory: root)
        #expect(try await reopened.status(request.id).state == "complete")
        #expect(try await reopened.replay(request.id, after: 0, limit: 100).first?.text == "Answer α\n")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for path in files { #expect(try !String(contentsOf: path, encoding: .utf8).contains(request.text!)) }
    }
    @Test func interruptedRestartAndExpiredRecordsNeverSilentlyRegenerate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = RequestJournal(directory: root, completedLimit: 1)
        let pending = RemoteAgentRequest("generate")
        _ = try await journal.begin(pending)
        let reopened = RequestJournal(directory: root, completedLimit: 1)
        #expect(try await reopened.status(pending.id).state == "interrupted")
        let next = RemoteAgentRequest("generate"); _ = try await reopened.begin(next)
        var done = RemoteAgentEvent("result", requestID: next.id); done.terminal = true
        _ = try await reopened.append(done)
        #expect(try await reopened.status(pending.id).state == "expired")
        await #expect(throws: Error.self) { _ = try await reopened.begin(pending) }
        let third = RequestJournal(directory: root, completedLimit: 1)
        #expect(try await third.status(pending.id).state == "expired")
        #expect(try await third.status(next.id).state == "complete")
    }
    @Test func partialDiskAppendIsRecoveredAndJournalBoundIsExplicit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = RequestJournal(directory: root, perRequestBytes: 2000)
        let request = RemoteAgentRequest("generate"); _ = try await journal.begin(request)
        let file = root.appendingPathComponent(request.id.uuidString + ".ndjson")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{partial".utf8)); try handle.close()
        let reopened = RequestJournal(directory: root, perRequestBytes: 2000)
        #expect(try await reopened.status(request.id).state == "interrupted")
        let again = RequestJournal(directory: root, perRequestBytes: 2000)
        #expect(try await again.status(request.id).state == "interrupted")
        let new = RemoteAgentRequest("generate"); _ = try await journal.begin(new)
        var token = RemoteAgentEvent("token", requestID: new.id); token.text = String(repeating: "x", count: 3000)
        await #expect(throws: Error.self) { _ = try await journal.append(token) }
    }
    @Test func recentEventsPublicationFollowsEveryOtherBackgroundDocument() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try "Latest".write(to: root.appendingPathComponent(RecentEvents.filename), atomically: true, encoding: .utf8)
        try "Other".write(to: root.appendingPathComponent("Z-Other.txt"), atomically: true, encoding: .utf8)
        try "Identity".write(to: root.appendingPathComponent("Identity.txt"), atomically: true, encoding: .utf8)
        #expect(try BackgroundPublication.read(directory: root).documents.map(\.filename) == ["Identity.txt", "Z-Other.txt", RecentEvents.filename])
    }
    @Test func backgroundPublicationOrdersHashesAndRefusesEscapingSymlinks() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try "R(MOVE)".write(to: root.appendingPathComponent("VerbFunctionExamples.tsv"), atomically: true, encoding: .utf8)
        try "α notation".write(to: root.appendingPathComponent("Notation.txt"), atomically: true, encoding: .utf8)
        let snapshot = try BackgroundPublication.read(directory: root)
        #expect(snapshot.documents.map(\.filename) == ["Notation.txt", "VerbFunctionExamples.tsv"])
        #expect(snapshot.assembledText == "BACKGROUND DOCUMENT: Notation.txt\nα notation\n\nBACKGROUND DOCUMENT: VerbFunctionExamples.tsv\nR(MOVE)")
        #expect(try BackgroundPublication.read(directory: root).id == snapshot.id)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside.txt"))
        #expect(throws: Error.self) { _ = try BackgroundPublication.read(directory: root) }
    }
}
