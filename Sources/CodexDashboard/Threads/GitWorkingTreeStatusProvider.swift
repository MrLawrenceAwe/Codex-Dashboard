import Foundation

protocol WorkingTreeStatusProviding: Sendable {
    func loadStatuses(
        for projectPaths: Set<String>,
        policy: WorkingTreeStatusRefreshPolicy
    ) async -> [String: WorkingTreeStatus]
}

enum WorkingTreeStatusRefreshPolicy: Equatable, Sendable {
    case useCached
    case refresh
}

actor GitWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    static let defaultStatusCacheLifetime: TimeInterval = 60

    private struct CachedStatus {
        let value: WorkingTreeStatus
        let loadedAt: Date
    }

    private enum RepositoryResolution: Sendable {
        case repository
        case terminal(WorkingTreeStatus)
    }

    private static let maximumConcurrentChecks = 6

    private let subprocessTimeout: TimeInterval
    private let cacheLifetime: TimeInterval
    private let statusLoader: @Sendable (String, TimeInterval) async -> WorkingTreeStatus
    private var statusByProjectPath: [String: CachedStatus] = [:]
    private var refreshGenerationByProjectPath: [String: UInt64] = [:]

    init(
        subprocessTimeout: TimeInterval = 3,
        cacheLifetime: TimeInterval = GitWorkingTreeStatusProvider.defaultStatusCacheLifetime,
        statusLoader: @escaping @Sendable (String, TimeInterval) async -> WorkingTreeStatus = {
            await GitWorkingTreeStatusProvider.status(atProjectPath: $0, timeout: $1)
        }
    ) {
        self.subprocessTimeout = subprocessTimeout
        self.cacheLifetime = cacheLifetime
        self.statusLoader = statusLoader
    }

    func loadStatuses(
        for projectPaths: Set<String>,
        policy: WorkingTreeStatusRefreshPolicy
    ) async -> [String: WorkingTreeStatus] {
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
        var statusesByProjectPath: [String: WorkingTreeStatus] = [:]
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
            let status: WorkingTreeStatus
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

    private static func status(
        atProjectPath path: String,
        timeout: TimeInterval
    ) async -> WorkingTreeStatus {
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
            guard tracked.standardOutput.isEmpty else { return .hasChanges }

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
            return untracked.standardOutput.isEmpty ? .clean : .hasChanges
        } catch {
            return .unavailable
        }
    }
}
