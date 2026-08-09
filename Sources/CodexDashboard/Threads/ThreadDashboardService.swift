import Foundation

actor ThreadDashboardService {
    private let catalogProvider: any ThreadCatalogProviding
    private let gitStatusProvider: any GitStatusProviding
    private let unreadIDProvider: any UnreadThreadIDProviding
    private var gitStatuses: [String: GitStatus] = [:]
    private var unreadThreadIDs: Set<String> = []
    private var hasLoadedCatalog = false

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
        if !hasLoadedCatalog,
           let latestUnreadIDs = try? await unreadIDProvider.loadUnreadThreadIDs() {
            unreadThreadIDs = latestUnreadIDs
        }
        let catalog = try await catalogProvider.loadCatalog(
            gitStatuses: gitStatuses,
            codexLaunchDate: codexLaunchDate
        )
        hasLoadedCatalog = true
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

    func refreshGitStatuses(in threads: [ThreadSummary]) async -> [ThreadSummary]? {
        let projectPaths = Set(threads.map(\.projectPath))
        guard !projectPaths.isEmpty, !Task.isCancelled else { return nil }
        let latestStatuses = await gitStatusProvider.load(projectPaths: projectPaths)
        guard !Task.isCancelled, latestStatuses != gitStatuses else { return nil }
        gitStatuses = latestStatuses
        return threads.map { source in
            var thread = source
            thread.gitStatus = latestStatuses[thread.projectPath] ?? .notRepository
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
