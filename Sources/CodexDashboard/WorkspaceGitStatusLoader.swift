import Foundation

protocol WorkspaceGitStatusLoading: Sendable {
    func load(at workspacePaths: Set<String>) async -> [String: WorkspaceGitStatus]
}

struct WorkspaceGitStatusLoader: WorkspaceGitStatusLoading, Sendable {
    private let subprocessTimeout: TimeInterval

    init(subprocessTimeout: TimeInterval = 3) {
        self.subprocessTimeout = subprocessTimeout
    }

    func load(at workspacePaths: Set<String>) async -> [String: WorkspaceGitStatus] {
        let timeout = subprocessTimeout
        return await withTaskGroup(
            of: (String, WorkspaceGitStatus).self,
            returning: [String: WorkspaceGitStatus].self
        ) { group in
            for path in workspacePaths {
                group.addTask {
                    (path, Self.status(at: path, timeout: timeout))
                }
            }
            var statuses: [String: WorkspaceGitStatus] = [:]
            for await (path, status) in group {
                statuses[path] = status
            }
            return statuses
        }
    }

    private static func status(at path: String, timeout: TimeInterval) -> WorkspaceGitStatus {
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "status", "--porcelain=v1", "--untracked-files=normal"],
                timeout: timeout
            )
            guard result.terminationStatus == 0 else { return .notRepository }
            return result.standardOutput.isEmpty ? .clean : .modified
        } catch {
            return .notRepository
        }
    }
}
