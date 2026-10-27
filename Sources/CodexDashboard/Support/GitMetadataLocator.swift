import Foundation

enum GitMetadataLocator {
    /// Finds the nearest marker, even when it is a damaged worktree pointer.
    /// Callers decide whether they need marker presence or validated metadata.
    static func markerURL(for projectURL: URL) -> URL? {
        var candidate = FileSystemPath.canonicalURL(projectURL.path)
        while true {
            let gitURL = candidate.appendingPathComponent(".git")
            if (try? FileManager.default.attributesOfItem(atPath: gitURL.path)) != nil { return gitURL }
            // Foundation versions differ in how deleting the root component is
            // represented. Stop before traversing above the filesystem root.
            guard candidate.path != "/", !candidate.path.isEmpty else { return nil }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    static func metadataURL(for projectURL: URL) -> URL? {
        guard let marker = markerURL(for: projectURL) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? marker : linkedMetadataURL(from: marker)
    }

    private static func linkedMetadataURL(from pointerURL: URL) -> URL? {
        guard
            let contents = try? String(contentsOf: pointerURL, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first,
            firstLine.hasPrefix("gitdir:")
        else { return nil }
        let rawPath = String(firstLine.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return nil }
        let metadataURL = URL(fileURLWithPath: rawPath, relativeTo: pointerURL.deletingLastPathComponent())
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: metadataURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return metadataURL
    }
}
