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

private struct FailingUnreadIDProvider: UnreadThreadIDProviding {
    func loadUnreadThreadIDs() throws -> Set<String> {
        throw UnreadThreadIDError.invalidState(URL(fileURLWithPath: "/tmp/global-state.json"))
    }
}

final class ThreadSnapshotServiceTests: XCTestCase {
    func testWorkingTreeUpdateChangesCurrentThreadsWithoutReloadingCatalog() async throws {
        let catalogProvider = CountingCatalogProvider()
        let service = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: ChangedWorkingTreeStatusProvider(),
            unreadIDProvider: EmptyUnreadIDProvider()
        )
        let snapshot = try await service.loadSnapshot(codexLaunchDate: nil)

        let updatedThreads = await service.updateWorkingTreeStatuses(in: snapshot.catalog.threads)
        let loadCount = await catalogProvider.loadCount

        XCTAssertEqual(updatedThreads?.first?.workingTreeStatus, .hasChanges)
        XCTAssertEqual(loadCount, 1)
    }

    func testUnreadFailureKeepsCatalogAvailableAndReportsWarning() async throws {
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            workingTreeStatusProvider: ChangedWorkingTreeStatusProvider(),
            unreadIDProvider: FailingUnreadIDProvider()
        )

        let snapshot = try await service.loadSnapshot(codexLaunchDate: nil)
        let refresh = await service.updateUnreadState(in: snapshot.catalog.threads)

        XCTAssertEqual(snapshot.catalog.threads.count, 1)
        XCTAssertFalse(snapshot.catalog.threads[0].isUnread)
        XCTAssertNotNil(snapshot.unreadStateWarning)
        XCTAssertNotNil(refresh.warning)
        XCTAssertNil(refresh.threads)
    }
}
