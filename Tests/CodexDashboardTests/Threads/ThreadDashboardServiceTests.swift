import XCTest

@testable import CodexDashboard

private actor CountingCatalogProvider: ThreadCatalogProviding {
    private(set) var loadCount = 0

    func loadCatalog(
        gitStatuses: [String: GitStatus],
        codexLaunchDate: Date?
    ) -> ThreadCatalog {
        loadCount += 1
        return ThreadCatalog(
            threads: [.fixture(gitStatus: gitStatuses["/tmp/project"] ?? .notRepository)],
            totalThreadCount: 1
        )
    }
}

private struct ChangedGitStatusProvider: GitStatusProviding {
    func load(projectPaths: Set<String>) -> [String: GitStatus] {
        Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, .hasChanges) })
    }
}

private struct EmptyUnreadIDProvider: UnreadThreadIDProviding {
    func loadUnreadThreadIDs() -> Set<String> { [] }
}

final class ThreadDashboardServiceTests: XCTestCase {
    func testGitRefreshUpdatesCurrentThreadsWithoutReloadingCatalog() async throws {
        let catalogProvider = CountingCatalogProvider()
        let service = ThreadDashboardService(
            catalogProvider: catalogProvider,
            gitStatusProvider: ChangedGitStatusProvider(),
            unreadIDProvider: EmptyUnreadIDProvider()
        )
        let catalog = try await service.loadCatalog(codexLaunchDate: nil)

        let updatedThreads = await service.refreshGitStatuses(in: catalog.threads)
        let loadCount = await catalogProvider.loadCount

        XCTAssertEqual(updatedThreads?.first?.gitStatus, .hasChanges)
        XCTAssertEqual(loadCount, 1)
    }
}
