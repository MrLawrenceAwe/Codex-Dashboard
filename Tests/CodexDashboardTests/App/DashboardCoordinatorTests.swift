import Combine
import XCTest

@testable import CodexDashboard

private struct StubCatalogProvider: ThreadCatalogProviding {
    let catalog: ThreadCatalog

    func loadCatalog(codexLaunchDate: Date?) async throws -> ThreadCatalog {
        catalog
    }
}

private struct StubWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    func loadStatuses(for projectPaths: Set<String>) async -> [String: WorkingTreeStatus] {
        [:]
    }
}

private struct StubUnreadIDProvider: UnreadThreadIDProviding {
    let unreadThreadIDs: Set<String>

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }
}

private struct FailingViewModelUnreadIDProvider: UnreadThreadIDProviding {
    func loadUnreadThreadIDs() async throws -> Set<String> {
        throw UnreadThreadIDError.invalidState(URL(fileURLWithPath: "/tmp/global-state.json"))
    }
}

private actor MutableUnreadIDProvider: UnreadThreadIDProviding {
    private var unreadThreadIDs: Set<String> = []

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }

    func setUnreadThreadIDs(_ threadIDs: Set<String>) {
        unreadThreadIDs = threadIDs
    }
}

private actor SuspendedCatalogProvider: ThreadCatalogProviding {
    private var continuations: [CheckedContinuation<ThreadCatalog, Never>] = []
    private(set) var requestCount = 0

    func loadCatalog(codexLaunchDate: Date?) async -> ThreadCatalog {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(
            returning: ThreadCatalog(threads: [], totalThreadCount: 0)
        )
    }

    func count() -> Int {
        requestCount
    }
}

private struct StubCompatibilityChecker: LocalCompatibilityChecking {
    let checks: [CompatibilityCheck]

    func checkLocalContracts() async -> [CompatibilityCheck] {
        checks
    }
}

@MainActor
private final class StubDashboardSession: DashboardSession {
    let codexIsRunning = false
    let codexLaunchDate: Date? = nil
    let maintainsDashboard = false
    private let compatibilityChecks: [CompatibilityCheck]
    private(set) var restartCallCount = 0
    private(set) var openedThreadIDs: [String] = []

    init(compatibilityChecks: [CompatibilityCheck] = []) {
        self.compatibilityChecks = compatibilityChecks
    }

    func rendererTargets() async -> [DevToolsTarget] { [] }
    func prepareForRestart() {}
    func restartCodex() async throws -> [DevToolsTarget] {
        restartCallCount += 1
        return []
    }
    func synchronizeDashboard(
        with snapshot: DashboardSnapshotPayload,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws {}
    func disableThreadDashboard() async throws -> DashboardDisableOutcome { .codexClosed }
    func openThreadDashboard() async {}
    func openThread(_ threadID: String) async { openedThreadIDs.append(threadID) }
    func rendererCompatibilityChecks() async -> [CompatibilityCheck] { compatibilityChecks }
}

@MainActor
final class DashboardCoordinatorTests: XCTestCase {
    func testRestartDoesNotBypassBlockingCompatibilityReport() async {
        let incompatible = CompatibilityCheck(
            id: "sidebar-host",
            title: "Sidebar integration",
            status: .incompatible,
            detail: "Missing sidebar"
        )
        let runtime = StubDashboardSession()
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: [incompatible]),
            runtimeFactory: { runtime }
        )
        await coordinator.checkCompatibility()

        await coordinator.restartCodexAndEnableThreadDashboard()

        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertTrue(coordinator.connectionError?.contains("incompatible") == true)
    }

    func testCompletionNotificationRoutesToItsThread() async throws {
        let runtime = StubDashboardSession()
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            runtimeFactory: { runtime }
        )

        NotificationCenter.default.post(
            name: .codexDashboardOpenCompletedThread,
            object: nil,
            userInfo: [CompletionNotificationPayload.threadIDKey: "completed-thread"]
        )
        try await waitUntil { runtime.openedThreadIDs == ["completed-thread"] }

        XCTAssertEqual(runtime.openedThreadIDs, ["completed-thread"])
        withExtendedLifetime(coordinator) {}
    }
    func testUnchangedSynchronizationDoesNotRepublishViewState() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            runtimeFactory: { StubDashboardSession() }
        )
        await coordinator.synchronizeDashboard()
        var publicationCount = 0
        let cancellable = coordinator.objectWillChange.sink { publicationCount += 1 }

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testCompatibilityCheckPublishesCapabilityReport() async {
        let expected = CompatibilityCheck(
            id: "storage",
            title: "Storage",
            status: .compatible,
            detail: "Healthy"
        )
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: [expected]),
            runtimeFactory: { StubDashboardSession() }
        )

        await coordinator.checkCompatibility()

        XCTAssertEqual(coordinator.compatibilityReport?.checks, [expected])
        XCTAssertFalse(coordinator.isCheckingCompatibility)
    }

    func testCompatibilityCheckAcknowledgesVersionOnlyAfterRendererInspection() async throws {
        let suiteName = "DashboardCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1.0", forKey: "lastCheckedCodexVersion")
        let unavailableRenderer = CompatibilityCheck(
            id: "renderer",
            title: "Renderer connection",
            status: .unavailable,
            detail: "Codex is closed."
        )
        let unavailableCoordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            userDefaults: defaults,
            installedCodexVersion: { "2.0" },
            runtimeFactory: {
                StubDashboardSession(compatibilityChecks: [unavailableRenderer])
            }
        )

        await unavailableCoordinator.checkCompatibility()
        XCTAssertEqual(defaults.string(forKey: "lastCheckedCodexVersion"), "1.0")

        let compatibleRenderer = CompatibilityCheck(
            id: "renderer",
            title: "Renderer connection",
            status: .compatible,
            detail: "Renderer inspected."
        )
        let compatibleCoordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            userDefaults: defaults,
            installedCodexVersion: { "2.0" },
            runtimeFactory: {
                StubDashboardSession(compatibilityChecks: [compatibleRenderer])
            }
        )

        await compatibleCoordinator.checkCompatibility()
        XCTAssertEqual(defaults.string(forKey: "lastCheckedCodexVersion"), "2.0")
    }

    func testSynchronizationUsesInjectedDependenciesWithoutStartingPolling() async {
        let thread = ThreadSummary.fixture(id: "thread-1", title: "Injected thread")
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 4)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: [thread.id]),
            runtimeFactory: { StubDashboardSession() }
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
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: unreadThreadIDProvider,
            runtimeFactory: { StubDashboardSession() }
        )
        await coordinator.synchronizeDashboard()
        await unreadThreadIDProvider.setUnreadThreadIDs([thread.id])
        await coordinator.refreshUnreadState()

        XCTAssertTrue(coordinator.threads.first?.isUnread == true)
    }

    func testUnreadFallbackPollingScheduleAvoidsHotFileReads() {
        XCTAssertEqual(DashboardPollingController.Schedule.unread(active: true), .seconds(10))
        XCTAssertEqual(DashboardPollingController.Schedule.unread(active: false), .seconds(30))
    }

    func testWorkingTreeFallbackPollingScheduleAvoidsRepeatedGitProcesses() {
        XCTAssertEqual(DashboardPollingController.Schedule.workingTree(active: true), .seconds(30))
        XCTAssertEqual(DashboardPollingController.Schedule.workingTree(active: false), .seconds(120))
    }

    func testUnreadFailureShowsWarningWithoutHidingCatalog() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: FailingViewModelUnreadIDProvider(),
            runtimeFactory: { StubDashboardSession() }
        )

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(coordinator.threads.map(\.id), [thread.id])
        XCTAssertTrue(coordinator.threadDataWarning?.contains("Unread state could not be refreshed") == true)
    }

    func testCancelledSynchronizationCannotClearNewSynchronizationTask() async throws {
        let catalogProvider = SuspendedCatalogProvider()
        let coordinator = DashboardCoordinator(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            runtimeFactory: { StubDashboardSession() }
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

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let conditionWasMet = await condition()
        XCTAssertTrue(conditionWasMet)
    }
}
