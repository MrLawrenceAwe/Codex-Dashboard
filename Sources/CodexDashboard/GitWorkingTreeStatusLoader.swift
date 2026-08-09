import Foundation

protocol GitWorkingTreeStatusLoading: Sendable {
    func load(at workspacePaths: Set<String>) async -> [String: GitWorkingTreeStatus]
}

struct GitWorkingTreeStatusLoader: GitWorkingTreeStatusLoading, Sendable {
    private let subprocessTimeout: TimeInterval

    init(subprocessTimeout: TimeInterval = 3) {
        self.subprocessTimeout = subprocessTimeout
    }

    func load(at workspacePaths: Set<String>) async -> [String: GitWorkingTreeStatus] {
        let timeout = subprocessTimeout
        return await withTaskGroup(
            of: (String, GitWorkingTreeStatus).self,
            returning: [String: GitWorkingTreeStatus].self
        ) { group in
            for path in workspacePaths {
                group.addTask {
                    (path, Self.status(at: path, timeout: timeout))
                }
            }
            var statuses: [String: GitWorkingTreeStatus] = [:]
            for await (path, status) in group {
                statuses[path] = status
            }
            return statuses
        }
    }

    private static func status(at path: String, timeout: TimeInterval) -> GitWorkingTreeStatus {
        guard FileManager.default.fileExists(atPath: path) else { return .unavailable }
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "status", "--porcelain=v1", "--untracked-files=normal"],
                timeout: timeout
            )
            guard result.terminationStatus == 0 else {
                let error = String(decoding: result.standardError, as: UTF8.self)
                return error.localizedCaseInsensitiveContains("not a git repository")
                    ? .notRepository
                    : .unavailable
            }
            return result.standardOutput.isEmpty ? .clean : .hasChanges
        } catch {
            return .unavailable
        }
    }
}
