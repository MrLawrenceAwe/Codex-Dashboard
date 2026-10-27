import Foundation

enum FileSystemPath {
    static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func canonicalPath(_ path: String) -> String {
        canonicalURL(path).path
    }

    static func gitRepositoryRoot(_ path: String) -> String? {
        let directory = canonicalURL(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return GitMetadataLocator.markerURL(for: directory)?.deletingLastPathComponent().path
    }
}
