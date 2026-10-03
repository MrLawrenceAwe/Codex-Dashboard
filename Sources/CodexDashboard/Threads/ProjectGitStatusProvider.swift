import Foundation

protocol ProjectGitStatusProviding: Sendable {
    func loadStatuses(
        for projectPaths: Set<String>,
        policy: ProjectGitStatusRefreshPolicy
    ) async -> [String: ProjectGitStatus]
}

enum ProjectGitStatusRefreshPolicy: Equatable, Sendable {
    case useCached
    case refresh
}

actor ProjectGitStatusProvider: ProjectGitStatusProviding {
    static let defaultStatusCacheLifetime: TimeInterval = 60

    private enum GitStatusError: Error { case unavailable }

    private struct CachedStatus {
        let value: ProjectGitStatus
        let loadedAt: Date
    }

    private enum RepositoryResolution: Sendable {
        case repository
        case terminal(ProjectGitStatus)
    }

    private static let maximumConcurrentChecks = 6

    private let subprocessTimeout: TimeInterval
    private let cacheLifetime: TimeInterval
    private let statusLoader: @Sendable (String, TimeInterval) async -> ProjectGitStatus
    private var statusByProjectPath: [String: CachedStatus] = [:]
    private var refreshGenerationByProjectPath: [String: UInt64] = [:]

    init(
        subprocessTimeout: TimeInterval = 3,
        cacheLifetime: TimeInterval = ProjectGitStatusProvider.defaultStatusCacheLifetime,
        statusLoader: @escaping @Sendable (String, TimeInterval) async -> ProjectGitStatus = {
            await ProjectGitStatusProvider.status(atProjectPath: $0, timeout: $1)
        }
    ) {
        self.subprocessTimeout = subprocessTimeout
        self.cacheLifetime = cacheLifetime
        self.statusLoader = statusLoader
    }

    func loadStatuses(
        for projectPaths: Set<String>,
        policy: ProjectGitStatusRefreshPolicy
    ) async -> [String: ProjectGitStatus] {
        guard !projectPaths.isEmpty else { return [:] }

        let now = Date()
        let resolutions = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            (path, Self.resolveRepository(at: path))
        })
        let timeout = subprocessTimeout

        let repositoryProjectPaths = projectPaths.filter { path in
            guard case .repository = resolutions[path] else { return false }
            return true
        }
        let staleProjectPaths = repositoryProjectPaths.filter { path in
            if policy == .refresh { return true }
            guard let cached = statusByProjectPath[path] else { return true }
            return now.timeIntervalSince(cached.loadedAt) >= cacheLifetime
        }
        var requestGenerations: [String: UInt64] = [:]
        for path in staleProjectPaths {
            let generation = (refreshGenerationByProjectPath[path] ?? 0) &+ 1
            refreshGenerationByProjectPath[path] = generation
            requestGenerations[path] = generation
        }
        let statusLoader = statusLoader
        let refreshed = await Self.concurrentMap(staleProjectPaths) { path in
            (path, await statusLoader(path, timeout))
        }
        var statusesByProjectPath: [String: ProjectGitStatus] = [:]
        for path in repositoryProjectPaths {
            guard let cached = statusByProjectPath[path],
                  now.timeIntervalSince(cached.loadedAt) < cacheLifetime
            else { continue }
            statusesByProjectPath[path] = cached.value
        }
        for (path, status) in refreshed {
            if refreshGenerationByProjectPath[path] == requestGenerations[path] {
                statusByProjectPath[path] = CachedStatus(value: status, loadedAt: Date())
                statusesByProjectPath[path] = status
            } else {
                statusesByProjectPath[path] = statusByProjectPath[path]?.value ?? status
            }
        }

        return Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let status: ProjectGitStatus
            switch resolutions[path] {
            case .repository:
                status = statusesByProjectPath[path] ?? .unavailable
            case .terminal(let value):
                status = value
            case nil:
                status = .unavailable
            }
            return (path, status)
        })
    }

    private static func concurrentMap<Element: Sendable, Result: Sendable>(
        _ elements: some Collection<Element>,
        operation: @escaping @Sendable (Element) async -> Result
    ) async -> [Result] {
        await withTaskGroup(of: Result.self, returning: [Result].self) { group in
            var iterator = elements.makeIterator()
            for _ in 0..<min(maximumConcurrentChecks, elements.count) {
                guard let element = iterator.next() else { break }
                group.addTask { await operation(element) }
            }
            var results: [Result] = []
            results.reserveCapacity(elements.count)
            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() {
                    group.addTask { await operation(next) }
                }
            }
            return results
        }
    }

    private static func resolveRepository(at path: String) -> RepositoryResolution {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .terminal(.unavailable) }

        var candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) {
                return .repository
            }
            guard candidate.path != "/", !candidate.path.isEmpty else {
                return .terminal(.notRepository)
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return .terminal(.notRepository) }
            candidate = parent
        }
    }

    // Uses local remote-tracking refs; refreshing the overview never contacts a remote.
    private static func hasUnpushedCommits(at path: String, timeout: TimeInterval) async throws -> Bool {
        func git(_ arguments: [String]) async throws -> SubprocessOutput {
            try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                                     arguments: ["--no-optional-locks", "-C", path] + arguments,
                                     timeout: timeout)
        }
        let remotes = try await git(["remote"])
        guard remotes.terminationStatus == 0 else { throw GitStatusError.unavailable }
        guard !remotes.standardOutput.isEmpty else { return false }
        let head = try await git(["rev-parse", "--verify", "HEAD"])
        guard head.terminationStatus == 0 else { return false } // New repository, no commits yet.
        let upstream = try await git(["rev-parse", "--verify", "@{upstream}"])
        let range = upstream.terminationStatus == 0
            ? [String(decoding: upstream.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) + "..HEAD"]
            : ["HEAD", "--not", "--remotes"]
        let commits = try await git(["rev-list", "--count"] + range)
        guard commits.terminationStatus == 0,
              let count = Int(String(decoding: commits.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw GitStatusError.unavailable }
        return count > 0
    }

    private static func status(
        atProjectPath path: String,
        timeout: TimeInterval
    ) async -> ProjectGitStatus {
        do {
            // Separate tracked and untracked checks. `git status --untracked-files=normal`
            // recursively expands untracked directories, which is needlessly expensive
            // for generated trees. `ls-files --directory` can stop at an untracked
            // directory while preserving the dashboard's dirty/clean contract.
            let tracked = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "--no-optional-locks", "-C", path,
                    "status", "--porcelain=v1", "--untracked-files=no", "--no-ahead-behind",
                    "--", ".", ":(exclude).DS_Store", ":(exclude)**/.DS_Store",
                ],
                timeout: timeout
            )
            guard tracked.terminationStatus == 0 else { return .unavailable }

            let untracked = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "--no-optional-locks", "-C", path,
                    "ls-files", "--others", "--exclude-standard", "--directory",
                    "--no-empty-directory", "--", ".",
                    ":(exclude).DS_Store", ":(exclude)**/.DS_Store",
                ],
                timeout: timeout
            )
            guard untracked.terminationStatus == 0 else { return .unavailable }
            let dirty = !tracked.standardOutput.isEmpty || !untracked.standardOutput.isEmpty
            let pending = try await hasUnpushedCommits(at: path, timeout: timeout)
            if pending { return dirty ? .uncommittedChangesAndUnpushedCommits : .unpushedCommits }
            return dirty ? .uncommittedChanges : .clean
        } catch {
            return .unavailable
        }
    }
}
