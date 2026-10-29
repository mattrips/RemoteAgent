import Foundation
import CryptoKit
import HarnessCore

/// Temporary output recovery, never a conversation archive. Prompts and tokens
/// supplied by clients are hashed for idempotency and are not written to disk.
public actor RequestJournal {
    private struct Header: Codable {
        var fingerprint: String
        var info: RemoteRequestInfo
    }
    private struct Record {
        var header: Header
        var events: [RemoteAgentEvent]
        var bytes: Int
        var terminal: Bool
    }
    private let directory: URL
    private var records: [UUID: Record] = [:]
    private var loaded = false
    private let perRequest: Int, totalLimit: Int, completedLimit: Int
    public init(directory: URL, perRequestBytes: Int = 8_000_000, totalBytes: Int = 64_000_000, completedLimit: Int = 16) {
        self.directory = directory; perRequest = perRequestBytes; totalLimit = totalBytes; self.completedLimit = completedLimit
    }
    public static func directory(secret: String) -> URL {
        let owner = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteAgent/RequestJournal/" + owner, isDirectory: true)
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".ndjson") }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func fingerprint(_ request: RemoteAgentRequest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
    }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "ndjson" }
        guard files.count <= 4096 else { throw HarnessError.state("journal_unavailable: too many recovery records; inspect the journal directory") }
        for url in files {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= perRequest + 65536 else { throw HarnessError.state("journal_unavailable: invalid recovery file") }
            let data = try Data(contentsOf: url), lines = data.split(separator: 10)
            guard let first = lines.first else { throw HarnessError.state("journal_unavailable: empty recovery file") }
            let header = try JSONDecoder().decode(Header.self, from: Data(first))
            var events: [RemoteAgentEvent] = []
            for (index, line) in lines.dropFirst().enumerated() {
                do {
                    let event = try JSONDecoder().decode(RemoteAgentEvent.self, from: Data(line))
                    guard event.requestID == id, event.sequence == index + 1 else { throw HarnessError.state("journal_unavailable: invalid event identity or sequence") }
                    events.append(event)
                } catch {
                    // A final partial append after termination is incomplete;
                    // reject interior corruption instead of silently skipping it.
                    if index == lines.count - 2, data.last != 10 { break }
                    throw error
                }
            }
            records[id] = .init(header: header, events: events, bytes: data.count, terminal: header.info.state == "expired" || events.last?.terminal == true)
            if data.last != 10 {
                var recovered = try JSONEncoder().encode(header) + Data([10])
                for event in events { recovered += try JSONEncoder().encode(event) + Data([10]) }
                try writePrivate(recovered, to: url)
                records[id]?.bytes = recovered.count
            }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? header.info.updatedAt
            records[id]?.header.info.updatedAt = modified
            records[id]?.header.info.expiresAt = modified.addingTimeInterval(3600)
            if let last = events.last {
                records[id]?.header.info.lastSequence = last.sequence ?? 0
                if last.terminal { records[id]?.header.info.state = last.kind == "error" ? (last.errorCode == "cancelled" ? "cancelled" : last.errorCode == "interrupted" ? "interrupted" : "failed") : "complete" }
            }
        }
        loaded = true
        for id in records.keys where records[id]?.terminal == false {
            // Never resume inference automatically after restarting the service.
            var event = RemoteAgentEvent.failure(id, code: "interrupted", message: "Service restarted before a terminal record. No automatic retry was made.")
            event.sequence = nil
            _ = try append(event)
            records[id]?.header.info.state = "interrupted"
        }
        try prune()
    }
    private func prune(reserving: Int = 0) throws {
        let now = Date()
        let completed = records.filter { $0.value.terminal && !$0.value.events.isEmpty }.sorted { $0.value.header.info.updatedAt < $1.value.header.info.updatedAt }
        var total = records.values.reduce(0) { $0 + $1.bytes } + reserving, count = completed.count
        for (id, value) in completed where value.header.info.expiresAt < now || count > completedLimit || total > totalLimit {
            // A small tombstone preserves an explicit expired response rather
            // than accidentally executing a repeated UUID as a new request.
            if value.events.isEmpty { continue }
            var header = value.header; header.info.state = "expired"
            let data = try JSONEncoder().encode(header) + Data([10])
            try writePrivate(data, to: file(id))
            total -= value.bytes - data.count; count -= 1
            records[id] = .init(header: header, events: [], bytes: data.count, terminal: true)
        }
        // Idempotency is bounded to the published recovery window. Retain
        // tombstones for an extra day, with a hard metadata ceiling.
        let tombstones = records.filter { $0.value.header.info.state == "expired" }.sorted { $0.value.header.info.createdAt < $1.value.header.info.createdAt }
        var retained = records.count
        for (id, value) in tombstones where value.header.info.updatedAt < now.addingTimeInterval(-86400) || retained >= 4096 {
            try FileManager.default.removeItem(at: file(id)); records.removeValue(forKey: id); retained -= 1
        }
    }
    /// Returns false for an existing identical request; the caller must report
    /// its saved status/replay instead of dispatching it to the model again.
    public func begin(_ request: RemoteAgentRequest) throws -> Bool {
        try load(); try prune()
        let hash = try fingerprint(request)
        if let existing = records[request.id] {
            guard existing.header.fingerprint == hash else { throw HarnessError.invalid("request_conflict: request UUID was already used with different input") }
            guard existing.header.info.state != "expired" else { throw HarnessError.state("request_expired: output recovery record expired; submit a NEW explicit request ID to retry") }
            return false
        }
        guard records.values.filter({ !$0.terminal }).count < 5, records.count < 4096 else { throw HarnessError.state("journal_busy: recovery record admission limit reached") }
        let header = Header(fingerprint: hash, info: .init(id: request.id, state: "queued"))
        let data = try JSONEncoder().encode(header) + Data([10])
        try writePrivate(data, to: file(request.id))
        records[request.id] = .init(header: header, events: [], bytes: data.count, terminal: false)
        return true
    }
    public func append(_ source: RemoteAgentEvent) throws -> RemoteAgentEvent {
        guard var record = records[source.requestID], !record.terminal else { throw HarnessError.state("journal_state: request is unknown or already terminal") }
        var event = source; event.sequence = record.header.info.lastSequence + 1
        let data = try JSONEncoder().encode(event) + Data([10])
        try prune(reserving: data.count)
        let limit = event.terminal ? perRequest + 65536 : perRequest
        guard record.bytes + data.count <= limit,
              records.values.reduce(0, { $0 + $1.bytes }) + data.count <= totalLimit else { throw HarnessError.state("journal_limit: bounded output recovery storage exceeded; partial output remains available") }
        let handle = try FileHandle(forWritingTo: file(source.requestID)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
        if event.terminal { try handle.synchronize() }
        record.events.append(event); record.bytes += data.count
        record.header.info.lastSequence += 1; record.header.info.updatedAt = Date(); record.header.info.expiresAt = Date().addingTimeInterval(3600)
        if event.kind == "requestState" { record.header.info.state = event.text ?? "running" }
        if event.terminal {
            record.terminal = true
            record.header.info.state = event.kind == "error" ? (event.errorCode == "cancelled" ? "cancelled" : event.errorCode == "interrupted" ? "interrupted" : "failed") : "complete"
        }
        records[source.requestID] = record
        try prune()
        return event
    }
    public func status(_ id: UUID) throws -> RemoteRequestInfo {
        try load(); try prune()
        guard let value = records[id] else { throw HarnessError.state("request_unknown: no recovery record; no request was started") }
        return value.header.info
    }
    public func expireCompletedRecords() throws { try load(); try prune() }
    public func markStorageFailure(_ id: UUID) {
        records[id]?.header.info.state = "recovery_unavailable"
        records[id]?.terminal = true
    }
    public func replay(_ id: UUID, after: Int, limit: Int) throws -> [RemoteAgentEvent] {
        let info = try status(id)
        guard info.state != "expired" else { throw HarnessError.state("request_expired: retained output is no longer available") }
        guard after <= info.lastSequence else { throw HarnessError.invalid("Replay cursor is beyond the saved output") }
        return Array((records[id]?.events ?? []).filter { ($0.sequence ?? 0) > after }.prefix(limit))
    }
}
