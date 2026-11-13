import CryptoKit
import Foundation

/// Hash file contents rather than Git's clean/dirty summary. A commit or staging
/// operation alone does not change this identity. Ignored build output is excluded.
enum GitWorktreeFingerprint {
    static func load(at path: String) async -> String? {
        do {
            let files = try await Subprocess.run(
                executableURL: GitExecutable.url,
                arguments: ["--no-optional-locks", "-C", path, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                            "--", ".", ":(exclude).DS_Store", ":(exclude)**/.DS_Store"],
                timeout: 3
            )
            guard files.terminationStatus == 0 else { return nil }
            let names = Set(files.standardOutput.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }).sorted()
            return try await Task.detached(priority: .utility) {
                let root = URL(fileURLWithPath: path, isDirectory: true)
                let manager = FileManager.default
                var hash = SHA256()
                func append(_ value: String) {
                    let bytes = Data(value.utf8)
                    hash.update(data: Data("\(bytes.count):".utf8))
                    hash.update(data: bytes)
                }
                for name in names {
                    try Task.checkCancellation()
                    let file = root.appendingPathComponent(name)
                    let attributes: [FileAttributeKey: Any]
                    do { attributes = try manager.attributesOfItem(atPath: file.path) }
                    catch CocoaError.fileReadNoSuchFile { continue }
                    append(name)
                    let type = attributes[.type] as? FileAttributeType
                    append(type?.rawValue ?? "unknown")
                    append((attributes[.posixPermissions] as? NSNumber)?.stringValue ?? "")
                    if type == .typeSymbolicLink {
                        append(try manager.destinationOfSymbolicLink(atPath: file.path))
                    } else if type == .typeRegular {
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        var content = SHA256()
                        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                            try Task.checkCancellation()
                            content.update(data: data)
                        }
                        append(content.finalize().map { String(format: "%02x", $0) }.joined())
                    } else {
                        // A submodule or special file needs a separate contract.
                        return nil
                    }
                }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
        } catch { return nil }
    }
}
