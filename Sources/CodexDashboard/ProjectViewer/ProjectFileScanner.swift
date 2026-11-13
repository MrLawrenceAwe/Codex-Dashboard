import Foundation

struct ProjectFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let bytes: Int
    let lines: Int?
    let functions: [ProjectFunction]
    let note: String?
}

struct ProjectScan: Sendable {
    let files: [ProjectFile]
    let warnings: [String]
}

enum ProjectFileScanner {
    static let maximumFileBytes = 1_048_576
    static let maximumScanBytes = 64 * 1_048_576
    static let excludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", ".next", ".nuxt", ".venv", "venv",
        "__pycache__", "dist", "build", "target", "coverage", "Pods", "Carthage", ".cache"
    ]

    static func scan(root: URL) throws -> ProjectScan {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var warnings: [String] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, _ in
            warnings.append("Could not read \(url.lastPathComponent).")
            return true
        }) else { throw CocoaError(.fileReadNoPermission) }
        var files: [ProjectFile] = []
        var totalBytes = 0
        var visited = 0
        var reachedByteLimit = false
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            if visited > 30_000 { warnings.append("Scan limited to 30,000 entries."); break }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) || url.pathExtension == "app" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let size = values.fileSize ?? 0
            let note: String?
            var lines: Int?
            var functions: [ProjectFunction] = []
            if size > maximumFileBytes { note = "Over 1 MB; preview skipped" }
            else if totalBytes + size > maximumScanBytes {
                reachedByteLimit = true
                note = "Scan byte limit reached"
            }
            else {
                totalBytes += size
                do {
                    let text = try readText(at: url)
                    lines = ProjectSourceAnalyzer.lineCount(text)
                    functions = ProjectSourceAnalyzer.functions(in: text, extension: url.pathExtension.lowercased())
                    note = nil
                } catch { note = "Binary, non-UTF-8, or unreadable" }
            }
            files.append(ProjectFile(path: path, bytes: size, lines: lines, functions: functions, note: note))
        }
        if reachedByteLimit { warnings.append("Some files exceeded the 64 MB scan budget.") }
        return ProjectScan(files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, warnings: warnings)
    }

    static func readText(at url: URL) throws -> String {
        // Use a bounded read even if a file grows between metadata and opening it.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
