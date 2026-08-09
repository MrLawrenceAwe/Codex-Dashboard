import Foundation

actor ThreadSnapshotService {
    private let catalogProvider: any ThreadCatalogProviding
    private let workingTreeStatusProvider: any WorkingTreeStatusProviding
    private let unreadIDProvider: any UnreadThreadIDProviding
    private var workingTreeStatuses: [String: WorkingTreeStatus] = [:]
    private var unreadThreadIDs: Set<String> = []
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

    func loadSnapshot(codexLaunchDate: Date?) async throws -> ThreadCatalog {
        if !hasLoadedSnapshot,
           let latestUnreadIDs = try? await unreadIDProvider.loadUnreadThreadIDs() {
            unreadThreadIDs = latestUnreadIDs
        }
        let catalog = try await catalogProvider.loadCatalog(
            workingTreeStatuses: workingTreeStatuses,
            codexLaunchDate: codexLaunchDate
        )
        hasLoadedSnapshot = true
        return ThreadCatalog(
            threads: applyingUnreadState(to: catalog.threads),
            totalThreadCount: catalog.totalThreadCount
        )
    }

    func updateUnreadState(in threads: [ThreadSummary]) async -> [ThreadSummary]? {
        guard
            let latestUnreadIDs = try? await unreadIDProvider.loadUnreadThreadIDs(),
            latestUnreadIDs != unreadThreadIDs
        else { return nil }
        unreadThreadIDs = latestUnreadIDs
        let updatedThreads = applyingUnreadState(to: threads)
        return updatedThreads == threads ? nil : updatedThreads
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
}
