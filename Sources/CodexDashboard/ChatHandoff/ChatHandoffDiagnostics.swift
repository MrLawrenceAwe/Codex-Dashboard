import Foundation

/// Bounded lifecycle diagnostics. Request parameters, credentials and raw stderr
/// are never written to disk.
struct ChatHandoffDiagnostics {
    let root: URL

    func record(_ event: String) {
        let manager = FileManager.default
        let file = root.appendingPathComponent("diagnostics.log")
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 1_048_576 {
                let previous = root.appendingPathComponent("diagnostics.previous.log")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: file.path) {
                manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let line = ISO8601DateFormatter().string(from: .now) + " " + event + "\n"
            try handle.write(contentsOf: Data(line.utf8))
        } catch { /* Diagnostics must not interrupt the writer or expose secrets. */ }
    }

    static func method(_ value: String) -> String {
        value.range(of: #"^[a-zA-Z0-9/_-]{1,128}$"#, options: .regularExpression) != nil ? value : "unrecognized-method"
    }

    func stderr(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        let category: String
        if text.contains("panic") { category = "panic" }
        else if text.contains("config") { category = "configuration" }
        else if text.contains("auth") { category = "authentication" }
        else if text.contains("error") { category = "error" }
        else { category = "other" }
        record("writer.stderr category=\(category) bytes=\(data.count)")
    }
}
