import Foundation

enum FileSystemPath {
    static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func canonicalPath(_ path: String) -> String {
        canonicalURL(path).path
    }

    static func gitRepositoryRoot(_ path: String) -> String? {
        var directory = canonicalURL(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                // A .git file identifies a worktree or submodule just as a directory does.
                return directory.path
            }
            guard directory.path != "/" else { return nil }
            directory.deleteLastPathComponent()
        }
    }
}
