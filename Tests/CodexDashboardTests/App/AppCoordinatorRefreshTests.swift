import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testLiveCoordinatorSynchronizationWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 to synchronize with the live Codex renderer.")
        }
        let coordinator = AppCoordinator(observeFileChanges: false)

        await coordinator.checkCompatibility()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(
            coordinator.connectionState,
            .dashboardMounted,
            coordinator.connectionError ?? coordinator.connectionNotice ?? "No connection detail was reported."
        )
        XCTAssertNil(coordinator.connectionError)
    }

    func testFailedRefreshPreservesAnAlreadyMountedDashboardState() async {
        let runtime = StubDashboardRuntime(
            maintainsDashboard: true,
            synchronizationError: AccountTestError.mountFailed
        )
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(catalog: ThreadCatalog(threads: [], totalThreadCount: 0)),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            runtimeFactory: { runtime }
        )
        coordinator.connectionState = .dashboardMounted

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(coordinator.connectionState, .dashboardMounted)
        XCTAssertNil(coordinator.connectionError)
        XCTAssertEqual(coordinator.connectionNotice, AccountTestError.mountFailed.localizedDescription)
        XCTAssertEqual(coordinator.statusPresentation.title, "Task Dashboard is live")
    }

    func testUnchangedSynchronizationDoesNotRepublishViewState() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { StubDashboardRuntime() }
        )
        await coordinator.synchronizeDashboard()
        var publicationCount = 0
        let cancellable = coordinator.objectWillChange.sink { publicationCount += 1 }

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testSynchronizationUsesInjectedDependenciesWithoutStartingPolling() async {
        let thread = ThreadSummary.fixture(id: "thread-1", title: "Injected thread")
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 4)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: [thread.id]),
            runtimeFactory: { StubDashboardRuntime() }
        )

        XCTAssertEqual(coordinator.connectionState, .checking)
        await coordinator.synchronizeDashboard()

        XCTAssertTrue(coordinator.threads.first?.isUnread == true)
        XCTAssertEqual(coordinator.totalThreadCount, 4)
        XCTAssertEqual(coordinator.connectionState, .codexClosed)
        XCTAssertEqual(coordinator.statusPresentation.title, "Codex is closed")
    }

    func testUnreadRefreshUpdatesThread() async throws {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let unreadThreadIDProvider = MutableUnreadIDProvider()
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: unreadThreadIDProvider,
            runtimeFactory: { StubDashboardRuntime() }
        )
        await coordinator.synchronizeDashboard()
        await unreadThreadIDProvider.setUnreadThreadIDs([thread.id])
        await coordinator.refreshUnreadState()

        XCTAssertTrue(coordinator.threads.first?.isUnread == true)
    }

    func testActivationRefreshUsesWorkingTreeCache() async {
        let thread = ThreadSummary.fixture(id: "thread-1", workingTreeStatus: .notRepository)
        let workingTreeStatusProvider = MutableWorkingTreeStatusProvider(status: .hasChanges)
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.refreshAfterActivation()
        XCTAssertEqual(coordinator.threads.first?.workingTreeStatus, .hasChanges)

        await workingTreeStatusProvider.setStatus(.clean)
        await coordinator.refreshAfterActivation()
        XCTAssertEqual(coordinator.threads.first?.workingTreeStatus, .clean)
        let latestPolicy = await workingTreeStatusProvider.latestPolicy()
        XCTAssertEqual(latestPolicy, .useCached)
    }

    func testActivationDoesNotDuplicateInitialWorkingTreeRefreshWhenMonitoringIsAvailable() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let workingTreeStatusProvider = MutableWorkingTreeStatusProvider(status: .clean)
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: true,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.refreshAfterActivation()

        let requestCount = await workingTreeStatusProvider.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testCatalogPollingKeepsLifecycleTrackingResponsiveWhenFileEventsAreAvailable() {
        XCTAssertEqual(
            RefreshScheduler.Schedule.catalog(active: true),
            .seconds(2)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.catalog(active: false),
            .seconds(8)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.unread(active: true, fileEventsAvailable: true),
            .seconds(15)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.unread(active: false, fileEventsAvailable: true),
            .seconds(60)
        )
    }

    func testNewlyDiscoveredProjectGetsImmediateWorkingTreeRefresh() async throws {
        let thread = ThreadSummary.fixture(
            id: "new-project",
            projectPath: "/tmp/new-project",
            workingTreeStatus: .notRepository
        )
        let workingTreeStatusProvider = MutableWorkingTreeStatusProvider(status: .hasChanges)
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()
        try await waitUntil {
            await workingTreeStatusProvider.requestCount() == 1
                && coordinator.threads.first?.workingTreeStatus == .hasChanges
        }

        let latestPolicy = await workingTreeStatusProvider.latestPolicy()
        XCTAssertEqual(latestPolicy, .refresh)
    }

    func testCatalogAndUnreadPollingRemainResponsiveWithoutFileEvents() {
        XCTAssertEqual(
            RefreshScheduler.Schedule.catalog(active: true),
            .seconds(2)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.catalog(active: false),
            .seconds(8)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.unread(active: true, fileEventsAvailable: false),
            .milliseconds(500)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.unread(active: false, fileEventsAvailable: false),
            .seconds(1)
        )
    }

    func testWorkingTreePollingScheduleIsOnlyAFallbackForFileEvents() {
        XCTAssertEqual(
            RefreshScheduler.Schedule.workingTree(active: true, fileEventsAvailable: true),
            .seconds(5 * 60)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.workingTree(active: false, fileEventsAvailable: true),
            .seconds(15 * 60)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.workingTree(active: true, fileEventsAvailable: false),
            .seconds(15)
        )
        XCTAssertEqual(
            RefreshScheduler.Schedule.workingTree(active: false, fileEventsAvailable: false),
            .seconds(60)
        )
    }

    func testUnreadFailureShowsWarningWithoutHidingCatalog() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: FailingViewModelUnreadIDProvider(),
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(coordinator.threads.map(\.id), [thread.id])
        XCTAssertTrue(coordinator.threadDataWarning?.contains("Unread state could not be refreshed") == true)
    }

    func testCancelledSynchronizationCannotClearNewSynchronizationTask() async throws {
        let catalogProvider = SuspendedCatalogProvider()
        let coordinator = makeAppCoordinator(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { StubDashboardRuntime() }
        )

        coordinator.startMonitoring()
        try await waitUntil { await catalogProvider.count() == 1 }
        coordinator.stopMonitoring()
        coordinator.startMonitoring()
        try await waitUntil { await catalogProvider.count() == 2 }

        await catalogProvider.resumeNext()
        try await Task.sleep(for: .milliseconds(50))
        let coalescedRefresh = Task { @MainActor in await coordinator.synchronizeDashboard() }
        try await Task.sleep(for: .milliseconds(50))
        let requestCount = await catalogProvider.count()
        XCTAssertEqual(requestCount, 2)

        await catalogProvider.resumeNext()
        try await waitUntil { await catalogProvider.count() == 3 }
        await catalogProvider.resumeNext()
        await coalescedRefresh.value
        coordinator.stopMonitoring()
    }

}
