import Foundation

struct ThreadSnapshotLoad: Sendable {
    let catalog: ThreadCatalog
    let unreadStateWarning: String?
}

struct UnreadStateRefresh: Sendable {
    let threads: [ThreadSummary]?
    let warning: String?
}

actor ThreadSnapshotService {
    private let catalogProvider: any ThreadCatalogProviding
    private let workingTreeStatusProvider: any WorkingTreeStatusProviding
    private let unreadIDProvider: any UnreadThreadIDProviding
    private var workingTreeStatuses: [String: WorkingTreeStatus] = [:]
    private var unreadThreadIDs: Set<String> = []
    private var unreadStateWarning: String?
    private var hasLoadedSnapshot = false

    init(
        catalogProvider: any ThreadCatalogProviding,
        workingTreeStatusProvider: any WorkingTreeStatusProviding,
        unreadIDProvider: any UnreadThreadIDProviding
    ) {
        self.catalogProvider = catalogProvider
        self.workingTreeStatusProvider = workingTreeStatusProvider
        self.unreadIDProvider = unreadIDProvider
    }

    func loadSnapshot(codexLaunchDate: Date?) async throws -> ThreadSnapshotLoad {
        if !hasLoadedSnapshot {
            do {
                unreadThreadIDs = try await unreadIDProvider.loadUnreadThreadIDs()
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
        return ThreadSnapshotLoad(
            catalog: ThreadCatalog(
                threads: applyingUnreadState(to: threads),
                totalThreadCount: catalog.totalThreadCount
            ),
            unreadStateWarning: unreadStateWarning
        )
    }

    func updateUnreadState(in threads: [ThreadSummary]) async -> UnreadStateRefresh {
        let latestUnreadIDs: Set<String>
        do {
            latestUnreadIDs = try await unreadIDProvider.loadUnreadThreadIDs()
            unreadStateWarning = nil
        } catch {
            unreadStateWarning = Self.warning(for: error)
            return UnreadStateRefresh(threads: nil, warning: unreadStateWarning)
        }
        guard latestUnreadIDs != unreadThreadIDs else {
            return UnreadStateRefresh(threads: nil, warning: nil)
        }
        unreadThreadIDs = latestUnreadIDs
        let updatedThreads = applyingUnreadState(to: threads)
        return UnreadStateRefresh(
            threads: updatedThreads == threads ? nil : updatedThreads,
            warning: nil
        )
    }

    func updateWorkingTreeStatuses(in threads: [ThreadSummary]) async -> [ThreadSummary]? {
        let projectPaths = Set(threads.map(\.projectPath))
        guard !projectPaths.isEmpty, !Task.isCancelled else { return nil }
        let latestStatuses = await workingTreeStatusProvider.load(projectPaths: projectPaths)
        guard !Task.isCancelled, latestStatuses != workingTreeStatuses else { return nil }
        workingTreeStatuses = latestStatuses
        return threads.map { source in
            var thread = source
            thread.workingTreeStatus = latestStatuses[thread.projectPath] ?? .notRepository
            return thread
        }
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
