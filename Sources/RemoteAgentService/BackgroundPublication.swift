import Foundation
import CryptoKit
import HarnessCore

public enum BackgroundPublication {
    public static var defaultDirectory: URL { EventualityPaths.defaultRoot.appendingPathComponent("Background Prompt", isDirectory: true) }
    public static func read(directory: URL) throws -> RemoteBackgroundSnapshot {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let preferred = ["Identity.txt", "ProjectIntro.txt", "GlossarySquibs.md", "Notation.txt", "VerbFunctionExamples.tsv"]
        func files() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                .filter { !$0.lastPathComponent.hasPrefix(".") && ["txt", "md", "tsv", "yaml", "json"].contains($0.pathExtension.lowercased()) }
                .sorted { a, b in
                    let ai = preferred.firstIndex(of: a.lastPathComponent) ?? preferred.count, bi = preferred.firstIndex(of: b.lastPathComponent) ?? preferred.count
                    return ai == bi ? a.lastPathComponent < b.lastPathComponent : ai < bi
                }
        }
        let paths = try files()
        guard !paths.isEmpty else { throw HarnessError.invalid("Configured background folder contains no supported documents") }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func readBounded(_ path: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
            let data = try handle.read(upToCount: 3_000_001) ?? Data()
            guard data.count <= 3_000_000 else { throw HarnessError.invalid("Background document grew beyond the publication limit") }; return data
        }
        var documents: [RemoteBackgroundDocument] = [], total = 0
        for path in paths {
            let resolved = path.resolvingSymlinksInPath().standardizedFileURL
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resolved.path.hasPrefix(root.path + "/"), values.isRegularFile == true,
                  let size = values.fileSize, size >= 0, size <= 3_000_000 - total else { throw HarnessError.invalid("Background path escapes the configured folder or exceeds the publication limit") }
            let data = try readBounded(resolved); total += data.count
            guard total <= 3_000_000, let content = String(data: data, encoding: .utf8) else { throw HarnessError.invalid("Background documents must be bounded UTF-8 text") }
            documents.append(.init(filename: path.lastPathComponent, content: content, sha256: digest(data)))
        }
        guard try files() == paths else { throw HarnessError.state("Background changed during publication; retry") }
        for (path, document) in zip(paths, documents) {
            guard path.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  try path.resourceValues(forKeys: [.fileSizeKey]).fileSize == document.byteCount,
                  try digest(readBounded(path)) == document.sha256 else { throw HarnessError.state("Background changed during publication; retry") }
        }
        let assembled = documents.map { "BACKGROUND DOCUMENT: \($0.filename)\n" + $0.content }.joined(separator: "\n\n")
        let value = RemoteBackgroundSnapshot(id: digest(Data(("decomposer-background-v1\n" + assembled).utf8)), documents: documents, assembledText: assembled)
        guard try JSONEncoder().encode(value).count < RemoteAgentLimits.maxFrameBytes - 4096 else { throw HarnessError.invalid("Encoded background snapshot exceeds the protocol frame limit") }
        return value
    }
}
