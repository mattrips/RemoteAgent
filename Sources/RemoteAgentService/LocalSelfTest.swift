import Foundation
import HarnessCore

/// Explicit local diagnostic. Credentials are used only in HTTP headers and are
/// never included in the saved report. No additional model is loaded.
public enum LocalSelfTest {
    public static func run(key: String, reportURL: URL) async throws -> String {
        let connection = Runner(key: key, reportURL: reportURL)
        return try await connection.run()
    }

    private final class Runner {
        let key: String
        let reportURL: URL
        let http: URLSession
        var records: [[String: Any]] = []
        init(key: String, reportURL: URL) {
            self.key = key; self.reportURL = reportURL
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 300
            http = URLSession(configuration: config)
        }
        deinit { http.invalidateAndCancel() }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw HarnessError.state("Local check failed: " + message) }
        }
        func call(_ operation: String, session: UUID? = nil, cache: UUID? = nil,
                  tokens: [Int]? = nil, messages: [ModelMessage]? = nil,
                  boundary: Int? = nil, maxTokens: Int? = nil, expectError: Bool = false,
                  temperature: Float = 0, topK: Int = 0, topP: Float = 1) async throws -> [RemoteAgentEvent] {
            var request = RemoteAgentRequest(operation)
            request.sessionID = session; request.cacheID = cache; request.tokens = tokens
            request.messages = messages; request.boundary = boundary; request.maxTokens = maxTokens
            request.temperature = temperature; request.topK = topK; request.topP = topP
            var url = URLRequest(url: URL(string: "http://127.0.0.1:8321/v1/rpc")!)
            url.httpMethod = "POST"; url.httpBody = try JSONEncoder().encode(request)
            url.setValue("application/json", forHTTPHeaderField: "Content-Type")
            url.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            let start = Date()
            let (data, response) = try await http.data(for: url)
            try require((response as? HTTPURLResponse)?.statusCode == 200, "HTTP request rejected")
            try require(data.count <= 8_000_000, "Diagnostic response too large")
            let events = try data.split(separator: 10).map { try JSONDecoder().decode(RemoteAgentEvent.self, from: Data($0)) }
            try require(events.allSatisfy { $0.version == 1 && $0.requestID == request.id }, "Response identity mismatch")
            try require(events.last?.terminal == true, "Missing terminal response")
            let record: [String: Any] = ["operation": operation, "seconds": Date().timeIntervalSince(start),
                "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))]
            records.append(record)
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try require((events.last?.kind == "error") == expectError, events.last?.text ?? "Unexpected error status")
            return events
        }
        func run() async throws -> String {
            let configuration = try await call("configuration")
            try require(configuration.last?.model != nil, "No loaded model")
            let first = try await call("session.create"), second = try await call("session.create")
            try require(first.last?.sessionCount != nil && second.last?.sessionCount != nil, "Session creation omitted dashboard counts")
            guard let session = first.last?.sessionID, let other = second.last?.sessionID else { throw HarnessError.state("No session IDs") }
            do {
                let rendered = try await call("tokenize", session: session, messages: [
                    ModelMessage(.system, "You are a concise assistant. Reply in plain text."),
                    ModelMessage(.user, "Say: RemoteAgent is ready.")])
                guard let tokens = rendered.last?.tokens, tokens.count > 5 else { throw HarnessError.state("No token IDs") }
                let prefill = try await call("cache.prefill", session: session, tokens: tokens)
                let progress = prefill.filter { $0.kind == "progress" }
                try require(progress.first?.prefillCompletedTokens == 0, "Prefill did not report its start")
                try require(progress.last?.prefillCompletedTokens == tokens.count && progress.last?.prefillTotalTokens == tokens.count,
                    "Prefill did not report completed new-token work")
                guard let base = prefill.last?.cacheID else { throw HarnessError.state("No baseline cache") }
                let initial = try await call("verify", session: session, cache: base, tokens: tokens)
                try require(initial.last?.replayEquivalent == true && initial.last?.equivalent == true, "Initial cache differs from cold execution")
                let half = tokens.count / 2
                let fork = try await call("cache.fork", session: session, cache: base, boundary: half)
                guard let branch = fork.last?.cacheID else { throw HarnessError.state("No fork cache") }
                let inspected = try await call("cache.inspect", session: session, cache: branch)
                try require(inspected.last?.tokens == Array(tokens.prefix(half)), "Fork contains incorrect tokens")
                let append = try await call("cache.append", session: session, cache: branch, tokens: Array(tokens.dropFirst(half)))
                guard let combined = append.last?.cacheID else { throw HarnessError.state("No appended cache") }
                let verified = try await call("verify", session: session, cache: combined, tokens: tokens)
                try require(verified.last?.replayEquivalent == true, "Fork-and-append differs from identical cold replay")
                let warm = try await call("generate", session: session, cache: base, tokens: tokens, maxTokens: 16)
                let split = try await call("generate", session: session, cache: combined, tokens: tokens, maxTokens: 16)
                let cold = try await call("generate", session: other, tokens: tokens, maxTokens: 16)
                func output(_ events: [RemoteAgentEvent]) -> [Int] { events.filter { $0.kind == "token" }.flatMap { $0.tokens ?? [] } }
                try require(!output(cold).isEmpty && output(warm) == output(cold) && output(split) == output(cold), "Cached and cold greedy outputs differ")
                try require(warm.compactMap(\.usage).last?.processedInputTokens == 0, "Full cache did not reuse all prompt tokens")
                let baselineAfter = try await call("verify", session: session, cache: base, tokens: tokens)
                let branchAfter = try await call("verify", session: session, cache: combined, tokens: tokens)
                try require(baselineAfter.last?.equivalent == true && branchAfter.last?.replayEquivalent == true, "Generation mutated an immutable cache")
                _ = try await call("cache.inspect", session: other, cache: base, expectError: true)
                _ = try await call("cache.inspect", session: session, cache: base)
                let capacity = configuration.last!.model!.contextCapacity
                _ = try await call("generate", session: session, tokens: Array(repeating: tokens[0], count: capacity), maxTokens: 1, expectError: true)
                let released = try await call("cache.release", session: session, cache: branch)
                try require(released.last?.cacheCount != nil && released.last?.cacheBytes != nil, "Cache release omitted dashboard counts")
                _ = try await call("cache.inspect", session: session, cache: branch, expectError: true)
                // Exercise Chat's actual non-greedy path, not just argmax.
                // Use the second session so no still-needed baseline is evicted.
                let sampled = try await call("generate", session: other, tokens: tokens, maxTokens: 16,
                    temperature: 0.6, topK: 20, topP: 0.95)
                try require(!output(sampled).isEmpty, "Chat top-k/top-p sampling returned no tokens")
                let categorical = try await call("generate", session: other, tokens: tokens, maxTokens: 16,
                    temperature: 0.6, topK: 0, topP: 1)
                try require(!output(categorical).isEmpty, "Temperature-only sampling returned no tokens")
                let closedFirst = try await call("session.close", session: session)
                let closedSecond = try await call("session.close", session: other)
                try require(closedFirst.last?.sessionCount != nil && closedFirst.last?.cacheCount != nil,
                    "Session close omitted dashboard counts")
                let current = try await call("status")
                try require(closedSecond.last?.sessionCount == current.last?.sessionCount && closedSecond.last?.cacheCount == current.last?.cacheCount,
                    "Session-close dashboard counts disagree with the server registry")
                let partitionWarning = verified.last?.equivalent != true
                return partitionWarning
                    ? "Local cache integrity and inference checks passed. Different batch partitions exceed the current logit tolerance; see the report."
                    : "Local cache integrity, numerical equivalence and inference checks passed."
            } catch {
                _ = try? await call("session.close", session: session)
                _ = try? await call("session.close", session: other)
                throw error
            }
        }
    }
}
