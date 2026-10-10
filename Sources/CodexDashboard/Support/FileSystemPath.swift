import Foundation

enum FileSystemPath {
    static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func canonicalPath(_ path: String) -> String {
        canonicalURL(path).path
    }
}
