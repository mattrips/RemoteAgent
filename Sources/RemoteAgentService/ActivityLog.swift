import Foundation
import HarnessCore

public struct RemoteActivityRecord: Sendable, Identifiable {
    public let id: UUID
    public let time: Date
    public var category: String
    public var client: String
    public var operation: String
    public var status: String
    public var requestID: UUID?
    public var sessionID: UUID?
    public var startedAt: Date?
    public var endedAt: Date?
    public var inputTokens: Int?
    public var reusedTokens: Int?
    public var generatedTokens: Int?
    public var errorCode: String?
    public var detail: String
}

/// Metadata only. Never retain request bodies, token IDs, output or raw errors.
struct RemoteActivityLog {
    static let capacity = 1000
    private(set) var records: [RemoteActivityRecord] = []
    private static let requests: Set<String> = ["generate", "tokenize", "cache.prefill", "cache.append", "cache.fork", "verify", "baseline.ensure"]
    static func label(_ text: String, limit: Int = 100) -> String {
        String(text.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(limit))
    }
    mutating func add(category: String, client: String = "Host", operation: String, status: String, requestID: UUID? = nil, sessionID: UUID? = nil, errorCode: String? = nil, detail: String = "", at: Date = Date()) {
        records.append(.init(id: UUID(), time: at, category: category, client: Self.label(client), operation: Self.label(operation), status: status, requestID: requestID, sessionID: sessionID, errorCode: errorCode.map { Self.label($0, limit: 64) }, detail: detail))
        while records.count > Self.capacity {
            let index = records.firstIndex { $0.category != "Request" || $0.endedAt != nil } ?? 0
            records.remove(at: index)
        }
    }
    mutating func begin(_ request: RemoteAgentRequest, client: String, running: Bool, at: Date = Date()) {
        guard Self.requests.contains(request.operation) else { return }
        if let i = records.lastIndex(where: { $0.category == "Request" && $0.requestID == request.id }) {
            if running, records[i].endedAt == nil { records[i].status = "Running"; records[i].startedAt = at }
            return
        }
        add(category: "Request", client: client, operation: request.operation, status: running ? "Running" : "Queued", requestID: request.id, sessionID: request.sessionID, at: at)
        records[records.count - 1].startedAt = running ? at : nil
        records[records.count - 1].inputTokens = request.tokens?.count
    }
    mutating func finish(_ event: RemoteAgentEvent, at: Date = Date()) {
        guard let i = records.lastIndex(where: { $0.category == "Request" && $0.requestID == event.requestID }) else { return }
        if let value = event.inputTokens ?? event.usage?.inputTokens { records[i].inputTokens = value }
        if let value = event.reusedTokens ?? event.usage?.reusedInputTokens { records[i].reusedTokens = value }
        if let value = event.generatedTokens ?? event.usage?.outputTokens { records[i].generatedTokens = value }
        guard event.terminal else { return }
        let state = event.kind == "error" ? (event.errorCode == "cancelled" ? "Cancelled" : event.errorCode == RepetitionDetectionError.code ? "Repetition detected" : "Failed") : "Complete"
        let duplicate = records[i].endedAt != nil && records[i].status == state && records[i].errorCode == event.errorCode
        records[i].status = state; records[i].endedAt = at; records[i].errorCode = event.errorCode.map { Self.label($0, limit: 64) }
        if event.kind == "error", !duplicate, event.errorCode != "cancelled" {
            let request = records[i]
            let detail = event.errorCode == RepetitionDetectionError.code && event.repetition?.valid == true
                ? "Exact consecutive repetition: \(event.repetition!.patternTokens)-token block × \(event.repetition!.repetitions); no result committed."
                : "Request failed; inspect the caller's diagnostic for details."
            add(category: "Error", client: request.client, operation: request.operation, status: state, requestID: request.requestID, sessionID: request.sessionID, errorCode: request.errorCode, detail: detail, at: at)
        }
    }
    mutating func sessionsChanged(from old: [RemoteSessionInfo], to new: [RemoteSessionInfo], at: Date = Date()) {
        let before = Set(old.map(\.id)), after = Set(new.map(\.id))
        for session in new where !before.contains(session.id) {
            add(category: "Connection", client: session.clientName + (session.deviceName.map { " · " + $0 } ?? ""), operation: "session", status: "Connected", sessionID: session.id, at: at)
        }
        for session in old where !after.contains(session.id) {
            add(category: "Connection", client: session.clientName + (session.deviceName.map { " · " + $0 } ?? ""), operation: "session", status: "Disconnected", sessionID: session.id, detail: "Session closed, expired, evicted, superseded or invalidated with its worker.", at: at)
        }
    }
    mutating func clear() { records.removeAll { $0.category != "Request" || $0.endedAt != nil } }
    func tracks(_ id: UUID) -> Bool { records.contains { $0.category == "Request" && $0.requestID == id } }
}
