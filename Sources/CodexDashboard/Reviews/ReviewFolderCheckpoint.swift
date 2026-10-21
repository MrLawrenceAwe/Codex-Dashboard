import CryptoKit
import Foundation

/// Content identity for ordinary folders. Never writes into the reviewed project.
/// Symlinks are recorded as links, without traversing their targets.
enum ReviewFolderCheckpoint {
    static func workspace(at path: String) async throws -> ReviewWorkspaceState {
        try await Task.detached(priority: .utility) {
            let root = FileSystemPath.canonicalURL(path)
            let first = try fingerprint(root)
            guard first == (try fingerprint(root)) else {
                throw ReviewLoopError("The folder changed while checking its files. Wait for other edits to finish, then Resume.")
            }
            return ReviewWorkspaceState(root: root.path, branch: "", revision: first, clean: true, kind: .folder)
        }.value
    }

    private static func fingerprint(_ root: URL) throws -> String {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReviewLoopError("The review folder is missing or unavailable: \(root.path)")
        }
        var hash = SHA256()
        func append(_ value: String) {
            let data = Data(value.utf8)
            hash.update(data: Data("\(data.count):".utf8))
            hash.update(data: data)
        }
        func visit(_ directory: URL) throws {
            let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                // Finder metadata is unrelated to the reviewed content.
                if child.lastPathComponent == ".DS_Store" { continue }
                let attributes = try manager.attributesOfItem(atPath: child.path)
                let type = attributes[.type] as? FileAttributeType
                append(String(child.path.dropFirst(root.path.count)))
                append(type?.rawValue ?? "unknown")
                append((attributes[.posixPermissions] as? NSNumber)?.stringValue ?? "")
                switch type {
                case .typeDirectory:
                    try visit(child)
                case .typeSymbolicLink:
                    append(try manager.destinationOfSymbolicLink(atPath: child.path))
                case .typeRegular:
                    let handle = try FileHandle(forReadingFrom: child)
                    defer { try? handle.close() }
                    var fileHash = SHA256()
                    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                        try Task.checkCancellation()
                        fileHash.update(data: data)
                    }
                    append(fileHash.finalize().map { String(format: "%02x", $0) }.joined())
                default:
                    throw ReviewLoopError("Cannot track this folder entry safely: \(child.path)")
                }
            }
        }
        try visit(root)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
