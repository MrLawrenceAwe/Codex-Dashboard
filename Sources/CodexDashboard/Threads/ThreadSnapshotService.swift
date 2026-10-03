import Foundation

struct ThreadSnapshotResult: Sendable {
    let catalog: ThreadCatalog
    let unreadStateWarning: String?
}

struct UnreadStateUpdate: Sendable {
    let unreadThreadIDs: Set<String>?
    let warning: String?
}

actor ThreadSnapshotService {
    private let catalogProvider: any ThreadCatalogProviding
    private let projectGitStatusProvider: any ProjectGitStatusProviding
    private let unreadThreadIDProvider: any UnreadThreadIDProviding
    private var projectGitStatuses: [String: ProjectGitStatus] = [:]
    private var unreadThreadIDs: Set<String> = []
    private var unreadStateWarning: String?
    private var hasLoadedSnapshot = false
    private var unreadRefreshGeneration: UInt64 = 0
    private var workingTreeGenerationByPath: [String: UInt64] = [:]

    init(
        catalogProvider: any ThreadCatalogProviding,
        projectGitStatusProvider: any ProjectGitStatusProviding,
        unreadThreadIDProvider: any UnreadThreadIDProviding
    ) {
        self.catalogProvider = catalogProvider
        self.projectGitStatusProvider = projectGitStatusProvider
        self.unreadThreadIDProvider = unreadThreadIDProvider
    }

    func loadSnapshot(codexLaunchDate: Date?) async throws -> ThreadSnapshotResult {
        if !hasLoadedSnapshot {
            unreadRefreshGeneration &+= 1
            let generation = unreadRefreshGeneration
            do {
                let latestUnreadIDs = try await unreadThreadIDProvider.loadUnreadThreadIDs()
                if generation == unreadRefreshGeneration {
                    unreadThreadIDs = latestUnreadIDs
                    unreadStateWarning = nil
                }
            } catch {
                if generation == unreadRefreshGeneration {
                    unreadStateWarning = Self.warning(for: error)
                }
            }
        }
        let catalog = try await catalogProvider.loadCatalog(
            codexLaunchDate: codexLaunchDate,
            requiredThreadIDs: unreadThreadIDs
        )
        hasLoadedSnapshot = true
        let threads = catalog.threads.map { source in
            var thread = source
            thread.projectGitStatus = projectGitStatuses[thread.projectGroupPath ?? ""] ?? .notRepository
            return thread
        }
        return ThreadSnapshotResult(
            catalog: ThreadCatalog(
                threads: applyingUnreadState(to: threads),
                totalThreadCount: catalog.totalThreadCount
            ),
            unreadStateWarning: unreadStateWarning
        )
    }

    func updateUnreadState() async -> UnreadStateUpdate {
        unreadRefreshGeneration &+= 1
        let generation = unreadRefreshGeneration
        let latestUnreadIDs: Set<String>
        do {
            latestUnreadIDs = try await unreadThreadIDProvider.loadUnreadThreadIDs()
        } catch {
            guard generation == unreadRefreshGeneration else {
                return UnreadStateUpdate(unreadThreadIDs: nil, warning: unreadStateWarning)
            }
            unreadStateWarning = Self.warning(for: error)
            return UnreadStateUpdate(unreadThreadIDs: nil, warning: unreadStateWarning)
        }
        guard generation == unreadRefreshGeneration else {
            return UnreadStateUpdate(unreadThreadIDs: nil, warning: unreadStateWarning)
        }
        unreadStateWarning = nil
        guard latestUnreadIDs != unreadThreadIDs else {
            return UnreadStateUpdate(unreadThreadIDs: nil, warning: nil)
        }
        unreadThreadIDs = latestUnreadIDs
        return UnreadStateUpdate(
            unreadThreadIDs: latestUnreadIDs,
            warning: nil
        )
    }

    func updateProjectGitStatuses(
        in threads: [ThreadSummary],
        projectPaths requestedPaths: Set<String>? = nil
    ) async -> [String: ProjectGitStatus]? {
        let allProjectPaths = Set(threads.compactMap(\.projectGroupPath))
        // WorkingTreeChangeMonitor already coalesces bursts. Do not discard the final event:
        // it may be the commit that clears the project's change indicator.
        let projectPaths = requestedPaths.map { $0.intersection(allProjectPaths) } ?? allProjectPaths
        guard !projectPaths.isEmpty, !Task.isCancelled else { return nil }

        var requestGenerations: [String: UInt64] = [:]
        for path in projectPaths {
            let generation = (workingTreeGenerationByPath[path] ?? 0) &+ 1
            workingTreeGenerationByPath[path] = generation
            requestGenerations[path] = generation
        }

        let policy: ProjectGitStatusRefreshPolicy = requestedPaths == nil ? .useCached : .refresh
        let latestStatuses = await projectGitStatusProvider.loadStatuses(
            for: projectPaths,
            policy: policy
        )
        guard !Task.isCancelled else { return nil }
        let currentResults = latestStatuses.filter { path, _ in
            workingTreeGenerationByPath[path] == requestGenerations[path]
        }
        guard !currentResults.isEmpty else { return nil }

        if requestedPaths == nil {
            projectGitStatuses = projectGitStatuses.filter { allProjectPaths.contains($0.key) }
            workingTreeGenerationByPath = workingTreeGenerationByPath.filter { allProjectPaths.contains($0.key) }
        }
        let changedResults = currentResults.filter { projectGitStatuses[$0.key] != $0.value }
        for (path, status) in currentResults {
            projectGitStatuses[path] = status
        }
        return changedResults.isEmpty ? nil : changedResults
    }

    private func applyingUnreadState(to threads: [ThreadSummary]) -> [ThreadSummary] {
        threads.map { source in
            var thread = source
            thread.isUnread = unreadThreadIDs.contains(thread.id)
            return thread
        }
    }

    private static func warning(for error: Error) -> String {
        "Unread state could not be refreshed. Showing the last known unread state. \(error.localizedDescription)"
    }
}
