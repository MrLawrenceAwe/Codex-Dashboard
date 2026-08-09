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
    func loadStatuses(for projectPaths: Set<String>) -> [String: WorkingTreeStatus] {
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

private actor SuspendedStatusCatalogProvider: ThreadCatalogProviding {
    private var continuation: CheckedContinuation<ThreadCatalog, Never>?

    func loadCatalog(
        workingTreeStatuses: [String: WorkingTreeStatus],
        codexLaunchDate: Date?
    ) async -> ThreadCatalog {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingLoad() -> Bool {
        continuation != nil
    }

    func resume(with workingTreeStatus: WorkingTreeStatus) {
        continuation?.resume(returning: ThreadCatalog(
            threads: [.fixture(workingTreeStatus: workingTreeStatus)],
            totalThreadCount: 1
        ))
        continuation = nil
    }
}

final class ThreadSnapshotServiceTests: XCTestCase {
    func testSnapshotReappliesGitStatusUpdatedWhileCatalogLoadIsSuspended() async throws {
        let catalogProvider = SuspendedStatusCatalogProvider()
        let service = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: ChangedWorkingTreeStatusProvider(),
            unreadThreadIDProvider: EmptyUnreadIDProvider()
        )
        let snapshotTask = Task {
            try await service.loadSnapshot(codexLaunchDate: nil)
        }
        while !(await catalogProvider.hasPendingLoad()) {
            await Task.yield()
        }

        let sourceThreads = [ThreadSummary.fixture(workingTreeStatus: .notRepository)]
        let updatedStatuses = await service.updateWorkingTreeStatuses(in: sourceThreads)
        XCTAssertEqual(updatedStatuses?["/tmp/project"], .hasChanges)
        await catalogProvider.resume(with: .notRepository)

        let snapshot = try await snapshotTask.value
        XCTAssertEqual(snapshot.catalog.threads.first?.workingTreeStatus, .hasChanges)
    }

    func testWorkingTreeUpdateChangesCurrentThreadsWithoutReloadingCatalog() async throws {
        let catalogProvider = CountingCatalogProvider()
        let service = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: ChangedWorkingTreeStatusProvider(),
            unreadThreadIDProvider: EmptyUnreadIDProvider()
        )
        let snapshot = try await service.loadSnapshot(codexLaunchDate: nil)

        let updatedStatuses = await service.updateWorkingTreeStatuses(in: snapshot.catalog.threads)
        let loadCount = await catalogProvider.loadCount

        XCTAssertEqual(updatedStatuses?["/tmp/project"], .hasChanges)
        XCTAssertEqual(loadCount, 1)
    }

    func testUnreadFailureKeepsCatalogAvailableAndReportsWarning() async throws {
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            workingTreeStatusProvider: ChangedWorkingTreeStatusProvider(),
            unreadThreadIDProvider: FailingUnreadIDProvider()
        )

        let snapshot = try await service.loadSnapshot(codexLaunchDate: nil)
        let refresh = await service.updateUnreadState()

        XCTAssertEqual(snapshot.catalog.threads.count, 1)
        XCTAssertFalse(snapshot.catalog.threads[0].isUnread)
        XCTAssertNotNil(snapshot.unreadStateWarning)
        XCTAssertNotNil(refresh.warning)
        XCTAssertNil(refresh.unreadThreadIDs)
    }
}
