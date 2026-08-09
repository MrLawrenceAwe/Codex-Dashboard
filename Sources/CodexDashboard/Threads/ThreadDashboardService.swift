import Foundation

actor ThreadDashboardService {
    private let catalogProvider: any ThreadCatalogProviding
    private let gitStatusProvider: any GitStatusProviding
    private let unreadIDProvider: any UnreadThreadIDProviding
    private var gitStatuses: [String: GitStatus] = [:]
    private var unreadThreadIDs: Set<String> = []

    init(
        catalogProvider: any ThreadCatalogProviding,
        gitStatusProvider: any GitStatusProviding,
        unreadIDProvider: any UnreadThreadIDProviding
    ) {
        self.catalogProvider = catalogProvider
        self.gitStatusProvider = gitStatusProvider
        self.unreadIDProvider = unreadIDProvider
    }

    func loadCatalog(codexLaunchDate: Date?) async throws -> ThreadCatalog {
        if let latestUnreadIDs = try? await unreadIDProvider.loadUnreadThreadIDs() {
            unreadThreadIDs = latestUnreadIDs
        }
        let catalog = try await catalogProvider.loadCatalog(
            gitStatuses: gitStatuses,
            codexLaunchDate: codexLaunchDate
        )
        return ThreadCatalog(
            threads: applyingUnreadState(to: catalog.threads),
            totalThreadCount: catalog.totalThreadCount
        )
    }

    func refreshUnreadState(in threads: [ThreadSummary]) async -> [ThreadSummary]? {
        guard
            let latestUnreadIDs = try? await unreadIDProvider.loadUnreadThreadIDs(),
            latestUnreadIDs != unreadThreadIDs
        else { return nil }
        unreadThreadIDs = latestUnreadIDs
        let updatedThreads = applyingUnreadState(to: threads)
        return updatedThreads == threads ? nil : updatedThreads
    }

    func refreshGitStatuses(for threads: [ThreadSummary]) async -> Bool {
        let projectPaths = Set(threads.map(\.projectPath))
        guard !projectPaths.isEmpty, !Task.isCancelled else { return false }
        let latestStatuses = await gitStatusProvider.load(projectPaths: projectPaths)
        guard !Task.isCancelled else { return false }
        let changed = latestStatuses != gitStatuses
        gitStatuses = latestStatuses
        return changed
    }

    private func applyingUnreadState(to threads: [ThreadSummary]) -> [ThreadSummary] {
        threads.map { source in
            var thread = source
            thread.isUnread = unreadThreadIDs.contains(thread.id)
            return thread
        }
    }
}
