import Foundation

enum GitMetadataLocator {
    static func metadataURL(for projectURL: URL) -> URL? {
        var candidate = projectURL.standardizedFileURL
        while true {
            let gitURL = candidate.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return gitURL }
                return linkedMetadataURL(from: gitURL)
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
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
