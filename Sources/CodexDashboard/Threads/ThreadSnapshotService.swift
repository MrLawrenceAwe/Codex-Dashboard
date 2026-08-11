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
    private let workingTreeStatusProvider: any WorkingTreeStatusProviding
    private let unreadThreadIDProvider: any UnreadThreadIDProviding
    private var workingTreeStatuses: [String: WorkingTreeStatus] = [:]
    private var unreadThreadIDs: Set<String> = []
    private var unreadStateWarning: String?
    private var hasLoadedSnapshot = false
    private var workingTreeGenerationByPath: [String: UInt64] = [:]

    init(
        catalogProvider: any ThreadCatalogProviding,
        workingTreeStatusProvider: any WorkingTreeStatusProviding,
        unreadThreadIDProvider: any UnreadThreadIDProviding
    ) {
        self.catalogProvider = catalogProvider
        self.workingTreeStatusProvider = workingTreeStatusProvider
        self.unreadThreadIDProvider = unreadThreadIDProvider
    }

    func loadSnapshot(codexLaunchDate: Date?) async throws -> ThreadSnapshotResult {
        if !hasLoadedSnapshot {
            do {
                unreadThreadIDs = try await unreadThreadIDProvider.loadUnreadThreadIDs()
                unreadStateWarning = nil
            } catch {
                unreadStateWarning = Self.warning(for: error)
            }
        }
        let catalog = try await catalogProvider.loadCatalog(
            codexLaunchDate: codexLaunchDate,
            requiredThreadIDs: unreadThreadIDs
        )
        hasLoadedSnapshot = true
        let threads = catalog.threads.map { source in
            var thread = source
            thread.workingTreeStatus = workingTreeStatuses[thread.projectPath] ?? .notRepository
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
        let latestUnreadIDs: Set<String>
        do {
            latestUnreadIDs = try await unreadThreadIDProvider.loadUnreadThreadIDs()
            unreadStateWarning = nil
        } catch {
            unreadStateWarning = Self.warning(for: error)
            return UnreadStateUpdate(unreadThreadIDs: nil, warning: unreadStateWarning)
        }
        guard latestUnreadIDs != unreadThreadIDs else {
            return UnreadStateUpdate(unreadThreadIDs: nil, warning: nil)
        }
        unreadThreadIDs = latestUnreadIDs
        return UnreadStateUpdate(
            unreadThreadIDs: latestUnreadIDs,
            warning: nil
        )
    }

    func updateWorkingTreeStatuses(
        in threads: [ThreadSummary],
        projectPaths requestedPaths: Set<String>? = nil
    ) async -> [String: WorkingTreeStatus]? {
        let allProjectPaths = Set(threads.map(\.projectPath))
        let projectPaths = requestedPaths.map { $0.intersection(allProjectPaths) } ?? allProjectPaths
        guard !projectPaths.isEmpty, !Task.isCancelled else { return nil }

        var requestGenerations: [String: UInt64] = [:]
        for path in projectPaths {
            let generation = (workingTreeGenerationByPath[path] ?? 0) &+ 1
            workingTreeGenerationByPath[path] = generation
            requestGenerations[path] = generation
        }

        let latestStatuses = await workingTreeStatusProvider.loadStatuses(for: projectPaths)
        guard !Task.isCancelled else { return nil }
        let currentResults = latestStatuses.filter { path, _ in
            workingTreeGenerationByPath[path] == requestGenerations[path]
        }
        guard !currentResults.isEmpty else { return nil }

        if requestedPaths == nil {
            workingTreeStatuses = workingTreeStatuses.filter { allProjectPaths.contains($0.key) }
            workingTreeGenerationByPath = workingTreeGenerationByPath.filter { allProjectPaths.contains($0.key) }
        }
        let changedResults = currentResults.filter { workingTreeStatuses[$0.key] != $0.value }
        for (path, status) in currentResults {
            workingTreeStatuses[path] = status
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
