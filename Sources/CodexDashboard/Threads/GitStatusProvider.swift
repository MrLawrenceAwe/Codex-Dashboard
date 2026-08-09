import Foundation

protocol GitStatusProviding: Sendable {
    func load(projectPaths: Set<String>) async -> [String: GitStatus]
}

struct SystemGitStatusProvider: GitStatusProviding, Sendable {
    private static let maximumConcurrentChecks = 6
    private let subprocessTimeout: TimeInterval

    init(subprocessTimeout: TimeInterval = 3) {
        self.subprocessTimeout = subprocessTimeout
    }

    func load(projectPaths: Set<String>) async -> [String: GitStatus] {
        let timeout = subprocessTimeout
        return await withTaskGroup(
            of: (String, GitStatus).self,
            returning: [String: GitStatus].self
        ) { group in
            var paths = projectPaths.makeIterator()
            for _ in 0..<min(Self.maximumConcurrentChecks, projectPaths.count) {
                guard let path = paths.next() else { break }
                group.addTask {
                    (path, Self.status(at: path, timeout: timeout))
                }
            }
            var statuses: [String: GitStatus] = [:]
            while let (path, status) = await group.next() {
                statuses[path] = status
                if let nextPath = paths.next() {
                    group.addTask {
                        (nextPath, Self.status(at: nextPath, timeout: timeout))
                    }
                }
            }
            return statuses
        }
    }

    private static func status(at path: String, timeout: TimeInterval) -> GitStatus {
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
