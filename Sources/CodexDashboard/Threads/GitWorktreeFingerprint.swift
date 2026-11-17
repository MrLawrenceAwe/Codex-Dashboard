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
            let staged = try await Subprocess.run(executableURL: GitExecutable.url,
                arguments: ["--no-optional-locks", "-C", path, "ls-files", "--stage", "-z", "--", "."], timeout: 3)
            guard staged.terminationStatus == 0 else { return nil }
            var submodules: [String: String] = [:]
            for record in staged.standardOutput.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9) else { return nil }
                let metadata = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard metadata.count == 3 else { return nil }
                guard metadata[0] == "160000" else { continue }
                guard metadata[2] == "0" else { return nil } // Unresolved gitlinks cannot establish a checkpoint.
                let name = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
                let directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
                guard let identity = try await submoduleIdentity(at: directory, indexRevision: String(metadata[1])) else { return nil }
                submodules[name] = identity
            }
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
                    if let identity = submodules[name] {
                        append(name)
                        append("submodule")
                        append(identity)
                        continue
                    }
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
                        // Special files cannot establish a content checkpoint.
                        return nil
                    }
                }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
        } catch { return nil }
    }

    private static func submoduleIdentity(at directory: URL, indexRevision: String) async throws -> String? {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: directory.path) }
        catch CocoaError.fileReadNoSuchFile {
            // A deinitialized submodule may have no working directory.
            return "unpopulated:" + indexRevision
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
        if !manager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            guard try manager.contentsOfDirectory(atPath: directory.path).isEmpty else { return nil }
            return "unpopulated:" + indexRevision
        }
        let root = try await Subprocess.run(executableURL: GitExecutable.url,
            arguments: ["--no-optional-locks", "-C", directory.path, "rev-parse", "--show-toplevel"], timeout: 3)
        var rootBytes = root.standardOutput
        if rootBytes.last == 10 { rootBytes.removeLast() }
        guard root.terminationStatus == 0,
              FileSystemPath.canonicalPath(String(decoding: rootBytes, as: UTF8.self)) == FileSystemPath.canonicalPath(directory.path)
        else { return nil }
        let head = try await Subprocess.run(executableURL: GitExecutable.url,
            arguments: ["--no-optional-locks", "-C", directory.path, "rev-parse", "--verify", "HEAD"], timeout: 3)
        guard head.terminationStatus == 0, let contents = await load(at: directory.path) else { return nil }
        return "populated:" + String(decoding: head.standardOutput, as: UTF8.self) + contents
    }
}
