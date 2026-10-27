import Foundation

enum FileSystemPath {
    static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func canonicalPath(_ path: String) -> String {
        canonicalURL(path).path
    }

    /// Compares normalized paths without filesystem access or symlink resolution.
    /// Callers choose canonical or lexical normalization before comparing.
    static func contains(_ path: String, in root: String) -> Bool {
        path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    static func overlaps(_ first: String, _ second: String) -> Bool {
        contains(first, in: second) || contains(second, in: first)
    }

    static func gitRepositoryRoot(_ path: String) -> String? {
        let directory = canonicalURL(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return GitMetadataLocator.markerURL(for: directory)?.deletingLastPathComponent().path
    }
}
