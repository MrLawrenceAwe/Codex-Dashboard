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
            workingTreeStatuses: workingTreeStatuses,
            codexLaunchDate: codexLaunchDate
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

    func updateWorkingTreeStatuses(in threads: [ThreadSummary]) async -> [String: WorkingTreeStatus]? {
        let projectPaths = Set(threads.map(\.projectPath))
        guard !projectPaths.isEmpty, !Task.isCancelled else { return nil }
        let latestStatuses = await workingTreeStatusProvider.loadStatuses(for: projectPaths)
        guard !Task.isCancelled, latestStatuses != workingTreeStatuses else { return nil }
        workingTreeStatuses = latestStatuses
        return latestStatuses
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
