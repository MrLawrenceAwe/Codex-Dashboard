import Foundation

protocol WorkingTreeStatusProviding: Sendable {
    func load(projectPaths: Set<String>) async -> [String: WorkingTreeStatus]
}

actor SystemWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    private struct CachedStatus {
        let value: WorkingTreeStatus
        let loadedAt: Date
    }

    private enum RepositoryResolution: Sendable {
        case repository(String)
        case terminal(WorkingTreeStatus)
    }

    private static let maximumConcurrentChecks = 6

    private let subprocessTimeout: TimeInterval
    private let cacheLifetime: TimeInterval
    private var repositoryRootByProjectPath: [String: String] = [:]
    private var statusByRepositoryRoot: [String: CachedStatus] = [:]

    init(subprocessTimeout: TimeInterval = 3, cacheLifetime: TimeInterval = 20) {
        self.subprocessTimeout = subprocessTimeout
        self.cacheLifetime = cacheLifetime
    }

    func load(projectPaths: Set<String>) async -> [String: WorkingTreeStatus] {
        guard !projectPaths.isEmpty else { return [:] }

        var resolutions: [String: RepositoryResolution] = [:]
        let unresolvedPaths = projectPaths.filter { path in
            guard let root = repositoryRootByProjectPath[path] else { return true }
            resolutions[path] = .repository(root)
            return false
        }
        let timeout = subprocessTimeout
        let resolved = await Self.concurrentMap(unresolvedPaths) { path in
            (path, Self.resolveRepository(at: path, timeout: timeout))
        }
        for (path, resolution) in resolved {
            resolutions[path] = resolution
            if case .repository(let root) = resolution {
                repositoryRootByProjectPath[path] = root
            }
        }

        let now = Date()
        let repositoryRoots = Set<String>(resolutions.values.compactMap { resolution in
            guard case .repository(let root) = resolution else { return nil }
            return root
        })
        let staleRoots = repositoryRoots.filter { root in
            guard let cached = statusByRepositoryRoot[root] else { return true }
            return now.timeIntervalSince(cached.loadedAt) >= cacheLifetime
        }
        let refreshed = await Self.concurrentMap(staleRoots) { root in
            (root, Self.status(atRepositoryRoot: root, timeout: timeout))
        }
        for (root, status) in refreshed {
            statusByRepositoryRoot[root] = CachedStatus(value: status, loadedAt: now)
        }

        return Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let status: WorkingTreeStatus
            switch resolutions[path] {
            case .repository(let root):
                status = statusByRepositoryRoot[root]?.value ?? .unavailable
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
        operation: @escaping @Sendable (Element) -> Result
    ) async -> [Result] {
        await withTaskGroup(of: Result.self, returning: [Result].self) { group in
            var iterator = elements.makeIterator()
            for _ in 0..<min(maximumConcurrentChecks, elements.count) {
                guard let element = iterator.next() else { break }
                group.addTask { operation(element) }
            }
            var results: [Result] = []
            results.reserveCapacity(elements.count)
            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() {
                    group.addTask { operation(next) }
                }
            }
            return results
        }
    }

    private static func resolveRepository(
        at path: String,
        timeout: TimeInterval
    ) -> RepositoryResolution {
        guard FileManager.default.fileExists(atPath: path) else { return .terminal(.unavailable) }
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "rev-parse", "--show-toplevel"],
                timeout: timeout
            )
            guard result.terminationStatus == 0 else {
                let error = String(decoding: result.standardError, as: UTF8.self)
                return error.localizedCaseInsensitiveContains("not a git repository")
                    ? .terminal(.notRepository)
                    : .terminal(.unavailable)
            }
            let root = String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return root.isEmpty ? .terminal(.unavailable) : .repository(root)
        } catch {
            return .terminal(.unavailable)
        }
    }

    private static func status(
        atRepositoryRoot root: String,
        timeout: TimeInterval
    ) -> WorkingTreeStatus {
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", root, "status", "--porcelain=v1", "--untracked-files=normal"],
                timeout: timeout
            )
            guard result.terminationStatus == 0 else { return .unavailable }
            return result.standardOutput.isEmpty ? .clean : .hasChanges
        } catch {
            return .unavailable
        }
    }
}
