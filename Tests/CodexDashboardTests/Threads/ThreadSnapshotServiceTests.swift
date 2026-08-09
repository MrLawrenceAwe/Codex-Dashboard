import XCTest

@testable import CodexDashboard

private actor CountingCatalogProvider: ThreadCatalogProviding {
    private(set) var loadCount = 0

    func loadCatalog(
        workingTreeStatuses: [String: WorkingTreeStatus],
        codexLaunchDate: Date?
    ) -> ThreadCatalog {
        loadCount += 1
        return ThreadCatalog(
            threads: [.fixture(workingTreeStatus: workingTreeStatuses["/tmp/project"] ?? .notRepository)],
            totalThreadCount: 1
        )
    }
}

private struct ChangedWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    func load(projectPaths: Set<String>) -> [String: WorkingTreeStatus] {
        Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, .hasChanges) })
    }
}

private struct EmptyUnreadIDProvider: UnreadThreadIDProviding {
    func loadUnreadThreadIDs() -> Set<String> { [] }
}

final class ThreadSnapshotServiceTests: XCTestCase {
    func testWorkingTreeUpdateChangesCurrentThreadsWithoutReloadingCatalog() async throws {
        let catalogProvider = CountingCatalogProvider()
        let service = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: ChangedWorkingTreeStatusProvider(),
            unreadIDProvider: EmptyUnreadIDProvider()
        )
        let catalog = try await service.loadSnapshot(codexLaunchDate: nil)

        let updatedThreads = await service.updateWorkingTreeStatuses(in: catalog.threads)
        let loadCount = await catalogProvider.loadCount

        XCTAssertEqual(updatedThreads?.first?.workingTreeStatus, .hasChanges)
        XCTAssertEqual(loadCount, 1)
    }
}
