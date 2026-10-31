import Foundation
import Darwin
import HarnessCore
import HarnessMLX

final class Output: @unchecked Sendable {
    let lock = NSLock()
    func send(_ event: RemoteAgentEvent) {
        guard let data = try? JSONEncoder().encode(event), data.count <= RemoteAgentLimits.maxFrameBytes else {
            send(.failure(event.requestID, code: "frame_too_large", message: "Worker result exceeds bounded protocol frame; no result committed")); return
        }
        lock.lock(); defer { lock.unlock() }
        do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) } catch { exit(74) }
    }
}
actor Host {
    let model: RemoteTokenModel
    let output: Output
    var active: (UUID, Task<Void, Never>)?
    init(_ model: RemoteTokenModel, _ output: Output) { self.model = model; self.output = output }
    func accept(_ request: RemoteAgentRequest) {
        if request.operation == "cancel" {
            if active?.0 == request.targetID { active?.1.cancel() }
            return
        }
        guard active == nil else { output.send(.failure(request.id, code: "busy", message: "Worker is busy", retryable: true)); return }
        let task = Task {
            do { try await model.perform(request, emit: { [output] in output.send($0) }) }
            catch {
                let message = error.localizedDescription
                let admissionOnly = message.hasPrefix("memory_admission:")
                let invalidates = !admissionOnly && ["MLX Error", "METAL", "memory_pressure"].contains { message.contains($0) }
                if invalidates { await model.invalidateCaches() }
                let repetition = error as? RepetitionDetectionError
                var failure = RemoteAgentEvent.failure(request.id, code: repetition != nil ? RepetitionDetectionError.code : error is CancellationError ? "cancelled" : admissionOnly ? "memory_admission" : "inference_failed", message: message + " No result was committed." + (invalidates ? " Cache handles were invalidated." : admissionOnly ? " No new inference state was created; snapshots may have been evicted for headroom." : " Existing immutable caches are unchanged."), retryable: false)
                failure.repetition = repetition?.match; failure.usage = repetition?.usage
                failure.pinStateKnown = true; failure.pinnedCache = await model.pinnedCacheInfo
                output.send(failure)
            }
            self.finished(request.id)
        }
        active = (request.id, task)
    }
    func finished(_ id: UUID) { if active?.0 == id { active = nil } }
}
@main struct Worker {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let output = Output()
        guard CommandLine.arguments.count == 2 else { exit(64) }
        do {
            let metal = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/mlx.metallib")
            let model = try await RemoteTokenModel.load(directory: URL(fileURLWithPath: CommandLine.arguments[1]), metalLibrary: FileManager.default.fileExists(atPath: metal.path) ? metal : nil)
            var configuration = RemoteAgentRequest("configuration"); configuration.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            try await model.perform(configuration, emit: { output.send($0) })
            let host = Host(model, output)
            // stdin is a private parent pipe, never a network socket. A bounded
            // parser prevents arbitrary lines growing the worker's CPU memory.
            await Task.detached {
                    var buffer = Data()
                    var bytes = [UInt8](repeating: 0, count: 65536)
                    do {
                        while !Task.isCancelled {
                            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { break }
                            buffer.append(contentsOf: bytes.prefix(count))
                            guard buffer.count <= RemoteAgentLimits.maxFrameBytes else { exit(65) }
                            while let newline = buffer.firstIndex(of: 10) {
                                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                                let request = try JSONDecoder().decode(RemoteAgentRequest.self, from: line)
                                await host.accept(request)
                            }
                        }
                    } catch { }
            }.value
        } catch { output.send(.failure(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, code: "load_failed", message: error.localizedDescription)); exit(70) }
    }
}
