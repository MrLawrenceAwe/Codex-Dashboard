import XCTest

@testable import CodexDashboard

private actor CountingCatalogProvider: ThreadCatalogProviding {
    private(set) var loadCount = 0

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) -> ThreadCatalog {
        loadCount += 1
        return ThreadCatalog(
            threads: [.fixture()],
            totalThreadCount: 1
        )
    }
}

private struct ChangedProjectGitStatusProvider: ProjectGitStatusProviding {
    func loadStatuses(
        for projectPaths: Set<String>,
        policy: ProjectGitStatusRefreshPolicy
    ) -> [String: ProjectGitStatus] {
        Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, .uncommittedChanges) })
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

private actor SequencedUnreadIDProvider: UnreadThreadIDProviding {
    private var continuations: [Int: CheckedContinuation<Set<String>, Never>] = [:]
    private var nextRequestID = 0
    private let suspendInitial: Bool

    init(suspendInitial: Bool = false) {
        self.suspendInitial = suspendInitial
    }

    func loadUnreadThreadIDs() async -> Set<String> {
        let requestID = nextRequestID
        nextRequestID += 1
        if requestID == 0 && !suspendInitial { return [] }
        return await withCheckedContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func pendingRequestCount() -> Int { continuations.count }

    func resume(requestID: Int, unreadThreadIDs: Set<String>) {
        continuations.removeValue(forKey: requestID)?.resume(returning: unreadThreadIDs)
    }
}

private actor SequencedProjectGitStatusProvider: ProjectGitStatusProviding {
    private var continuations: [Int: CheckedContinuation<[String: ProjectGitStatus], Never>] = [:]
    private var nextRequestID = 0

    func loadStatuses(
        for projectPaths: Set<String>,
        policy: ProjectGitStatusRefreshPolicy
    ) async -> [String: ProjectGitStatus] {
        let requestID = nextRequestID
        nextRequestID += 1
        return await withCheckedContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func pendingRequestCount() -> Int { continuations.count }

    func resume(requestID: Int, status: ProjectGitStatus) {
        continuations.removeValue(forKey: requestID)?.resume(returning: ["/tmp/project": status])
    }
}

private actor CountingProjectGitStatusProvider: ProjectGitStatusProviding {
    private var requests = 0

    func loadStatuses(
        for projectPaths: Set<String>,
        policy: ProjectGitStatusRefreshPolicy
    ) -> [String: ProjectGitStatus] {
        requests += 1
        return Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, requests == 1 ? .uncommittedChanges : .clean) })
    }

    func requestCount() -> Int { requests }
}

private actor SuspendedStatusCatalogProvider: ThreadCatalogProviding {
    private var continuation: CheckedContinuation<ThreadCatalog, Never>?

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingLoad() -> Bool {
        continuation != nil
    }

    func resume(with projectGitStatus: ProjectGitStatus) {
        continuation?.resume(returning: ThreadCatalog(
            threads: [.fixture(projectGitStatus: projectGitStatus)],
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
            projectGitStatusProvider: ChangedProjectGitStatusProvider(),
            unreadThreadIDProvider: EmptyUnreadIDProvider()
        )
        let snapshotTask = Task {
            try await service.loadSnapshot(codexLaunchDate: nil)
        }
        while !(await catalogProvider.hasPendingLoad()) {
            await Task.yield()
        }

        let sourceThreads = [ThreadSummary.fixture(projectGitStatus: .notRepository)]
        let updatedStatuses = await service.updateProjectGitStatuses(in: sourceThreads)
        XCTAssertEqual(updatedStatuses?["/tmp/project"], .uncommittedChanges)
        await catalogProvider.resume(with: .notRepository)

        let snapshot = try await snapshotTask.value
        XCTAssertEqual(snapshot.catalog.threads.first?.projectGitStatus, .uncommittedChanges)
    }

    func testWorkingTreeUpdateChangesCurrentThreadsWithoutReloadingCatalog() async throws {
        let catalogProvider = CountingCatalogProvider()
        let service = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            projectGitStatusProvider: ChangedProjectGitStatusProvider(),
            unreadThreadIDProvider: EmptyUnreadIDProvider()
        )
        let snapshot = try await service.loadSnapshot(codexLaunchDate: nil)

        let updatedStatuses = await service.updateProjectGitStatuses(in: snapshot.catalog.threads)
        let loadCount = await catalogProvider.loadCount

        XCTAssertEqual(updatedStatuses?["/tmp/project"], .uncommittedChanges)
        XCTAssertEqual(loadCount, 1)
    }

    func testOlderWorkingTreeRefreshCannotOverwriteNewerResult() async throws {
        let statusProvider = SequencedProjectGitStatusProvider()
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            projectGitStatusProvider: statusProvider,
            unreadThreadIDProvider: EmptyUnreadIDProvider()
        )
        let threads = [ThreadSummary.fixture(projectGitStatus: .notRepository)]

        let older = Task { await service.updateProjectGitStatuses(in: threads) }
        while await statusProvider.pendingRequestCount() < 1 { await Task.yield() }
        let newer = Task { await service.updateProjectGitStatuses(in: threads) }
        while await statusProvider.pendingRequestCount() < 2 { await Task.yield() }

        await statusProvider.resume(requestID: 1, status: .uncommittedChanges)
        let newerResult = await newer.value
        XCTAssertEqual(newerResult?["/tmp/project"], .uncommittedChanges)
        await statusProvider.resume(requestID: 0, status: .clean)
        let olderResult = await older.value
        XCTAssertNil(olderResult)

        let snapshot = try await service.loadSnapshot(codexLaunchDate: nil)
        XCTAssertEqual(snapshot.catalog.threads.first?.projectGitStatus, .uncommittedChanges)
    }

    func testRapidEventDrivenWorkingTreeRefreshPublishesFinalCleanStatus() async {
        let statusProvider = CountingProjectGitStatusProvider()
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            projectGitStatusProvider: statusProvider,
            unreadThreadIDProvider: EmptyUnreadIDProvider()
        )
        let threads = [ThreadSummary.fixture(projectGitStatus: .notRepository)]
        let paths: Set<String> = ["/tmp/project"]

        let initial = await service.updateProjectGitStatuses(in: threads, projectPaths: paths)
        let repeated = await service.updateProjectGitStatuses(in: threads, projectPaths: paths)
        let requestCount = await statusProvider.requestCount()

        XCTAssertEqual(initial?["/tmp/project"], .uncommittedChanges)
        XCTAssertEqual(repeated?["/tmp/project"], .clean)
        XCTAssertEqual(requestCount, 2)
    }

    func testUnreadFailureKeepsCatalogAvailableAndReportsWarning() async throws {
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            projectGitStatusProvider: ChangedProjectGitStatusProvider(),
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

    func testOlderUnreadRefreshCannotOverwriteNewerResult() async throws {
        let unreadProvider = SequencedUnreadIDProvider()
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            projectGitStatusProvider: ChangedProjectGitStatusProvider(),
            unreadThreadIDProvider: unreadProvider
        )
        _ = try await service.loadSnapshot(codexLaunchDate: nil)

        let older = Task { await service.updateUnreadState() }
        while await unreadProvider.pendingRequestCount() < 1 { await Task.yield() }
        let newer = Task { await service.updateUnreadState() }
        while await unreadProvider.pendingRequestCount() < 2 { await Task.yield() }

        await unreadProvider.resume(requestID: 2, unreadThreadIDs: ["newer"])
        let newerResult = await newer.value
        XCTAssertEqual(newerResult.unreadThreadIDs, ["newer"])
        await unreadProvider.resume(requestID: 1, unreadThreadIDs: ["older"])
        let olderResult = await older.value
        XCTAssertNil(olderResult.unreadThreadIDs)

        let unchanged = Task { await service.updateUnreadState() }
        while await unreadProvider.pendingRequestCount() < 1 { await Task.yield() }
        // A subsequent read of the same current state must not publish another change.
        await unreadProvider.resume(requestID: 3, unreadThreadIDs: ["newer"])
        let unchangedResult = await unchanged.value
        XCTAssertNil(unchangedResult.unreadThreadIDs)
    }

    func testInitialSnapshotDoesNotOverwriteNewerUnreadRefresh() async throws {
        let unreadProvider = SequencedUnreadIDProvider(suspendInitial: true)
        let service = ThreadSnapshotService(
            catalogProvider: CountingCatalogProvider(),
            projectGitStatusProvider: ChangedProjectGitStatusProvider(),
            unreadThreadIDProvider: unreadProvider
        )

        let snapshotTask = Task { try await service.loadSnapshot(codexLaunchDate: nil) }
        while await unreadProvider.pendingRequestCount() < 1 { await Task.yield() }
        let refreshTask = Task { await service.updateUnreadState() }
        while await unreadProvider.pendingRequestCount() < 2 { await Task.yield() }

        let unreadID = ThreadSummary.fixture().id
        await unreadProvider.resume(requestID: 1, unreadThreadIDs: [unreadID])
        let refresh = await refreshTask.value
        XCTAssertEqual(refresh.unreadThreadIDs, [unreadID])
        await unreadProvider.resume(requestID: 0, unreadThreadIDs: [])
        let snapshot = try await snapshotTask.value
        XCTAssertTrue(snapshot.catalog.threads[0].isUnread)
    }
}
