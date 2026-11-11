import Foundation

/// Prefer standalone Git so repository operations do not require an Xcode licence.
enum GitExecutable {
    static let url = resolve(
        searchPath: ProcessInfo.processInfo.environment["PATH"],
        isExecutable: FileManager.default.isExecutableFile(atPath:)
    )

    static func resolve(searchPath: String?, isExecutable: (String) -> Bool) -> URL {
        // GUI launches often omit Homebrew from PATH. Ignore relative entries so
        // a repository cannot supply the executable through the working directory.
        let directories = (searchPath ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("git").standardizedFileURL
            guard candidate.path != "/usr/bin/git", isExecutable(candidate.path) else { continue }
            return candidate
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }
}
