import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testUnchangedSynchronizationDoesNotRepublishViewState() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = AppCoordinator(
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
        let coordinator = AppCoordinator(
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
        let coordinator = AppCoordinator(
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

    func testActivationRefreshesWorkingTreeStatusImmediately() async {
        let thread = ThreadSummary.fixture(id: "thread-1", workingTreeStatus: .notRepository)
        let workingTreeStatusProvider = MutableWorkingTreeStatusProvider(status: .hasChanges)
        let coordinator = AppCoordinator(
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
        XCTAssertEqual(latestPolicy, .refresh)
    }

    func testCatalogAndUnreadPollingUseSlowFallbacksWhenFileEventsAreAvailable() {
        XCTAssertEqual(
            PollingController.Schedule.catalog(active: true, fileEventsAvailable: true),
            .seconds(30)
        )
        XCTAssertEqual(
            PollingController.Schedule.catalog(active: false, fileEventsAvailable: true),
            .seconds(2 * 60)
        )
        XCTAssertEqual(
            PollingController.Schedule.unread(active: true, fileEventsAvailable: true),
            .seconds(15)
        )
        XCTAssertEqual(
            PollingController.Schedule.unread(active: false, fileEventsAvailable: true),
            .seconds(60)
        )
    }

    func testCatalogAndUnreadPollingRemainResponsiveWithoutFileEvents() {
        XCTAssertEqual(
            PollingController.Schedule.catalog(active: true, fileEventsAvailable: false),
            .seconds(2)
        )
        XCTAssertEqual(
            PollingController.Schedule.catalog(active: false, fileEventsAvailable: false),
            .seconds(8)
        )
        XCTAssertEqual(
            PollingController.Schedule.unread(active: true, fileEventsAvailable: false),
            .milliseconds(500)
        )
        XCTAssertEqual(
            PollingController.Schedule.unread(active: false, fileEventsAvailable: false),
            .seconds(1)
        )
    }

    func testWorkingTreePollingScheduleIsOnlyAFallbackForFileEvents() {
        XCTAssertEqual(PollingController.Schedule.workingTree(active: true), .seconds(15))
        XCTAssertEqual(PollingController.Schedule.workingTree(active: false), .seconds(60))
    }

    func testUnreadFailureShowsWarningWithoutHidingCatalog() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = AppCoordinator(
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
        let coordinator = AppCoordinator(
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
