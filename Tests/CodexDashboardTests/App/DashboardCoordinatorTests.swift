import Combine
import XCTest

@testable import CodexDashboard

private struct StubCatalogProvider: ThreadCatalogProviding {
    let catalog: ThreadCatalog

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async throws -> ThreadCatalog {
        catalog
    }
}

private struct StubWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    func loadStatuses(for projectPaths: Set<String>) async -> [String: WorkingTreeStatus] {
        [:]
    }
}

private actor MutableWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    private var status: WorkingTreeStatus

    init(status: WorkingTreeStatus) {
        self.status = status
    }

    func loadStatuses(for projectPaths: Set<String>) -> [String: WorkingTreeStatus] {
        Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, status) })
    }

    func setStatus(_ status: WorkingTreeStatus) {
        self.status = status
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

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
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

private actor SequencedCatalogProvider: ThreadCatalogProviding {
    private var catalogs: [ThreadCatalog]

    init(catalogs: [ThreadCatalog]) {
        self.catalogs = catalogs
    }

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
        guard catalogs.count > 1 else {
            return catalogs.first ?? ThreadCatalog(threads: [], totalThreadCount: 0)
        }
        return catalogs.removeFirst()
    }
}

@MainActor
private final class RecordingCodexForegrounder: CodexForegrounding {
    private(set) var callCount = 0

    func foregroundCodex() {
        callCount += 1
    }
}

private struct StubCompatibilityChecker: LocalCompatibilityChecking {
    let checks: [CompatibilityCheck]

    func checkLocalContracts() async -> [CompatibilityCheck] {
        checks
    }
}

private actor SequencedCompatibilityChecker: LocalCompatibilityChecking {
    private var results: [[CompatibilityCheck]]

    init(results: [[CompatibilityCheck]]) {
        self.results = results
    }

    func checkLocalContracts() async -> [CompatibilityCheck] {
        guard results.count > 1 else { return results.first ?? [] }
        return results.removeFirst()
    }
}

@MainActor
private final class StubDashboardRuntime: DashboardRuntime {
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
        let runtime = StubDashboardRuntime()
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

    func testRestartRechecksAndClearsStaleBlockingCompatibilityReport() async {
        let incompatible = CompatibilityCheck(
            id: "thread-database",
            title: "Thread catalog",
            status: .incompatible,
            detail: "Temporary inspection failure"
        )
        let compatible = CompatibilityCheck(
            id: "thread-database",
            title: "Thread catalog",
            status: .compatible,
            detail: "Healthy"
        )
        let checker = SequencedCompatibilityChecker(results: [[incompatible], [compatible]])
        let runtime = StubDashboardRuntime()
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: checker,
            runtimeFactory: { runtime }
        )
        await coordinator.checkCompatibility()

        await coordinator.restartCodexAndEnableThreadDashboard()

        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertEqual(coordinator.compatibilityReport?.blockingCount, 0)
        XCTAssertNil(coordinator.connectionError)
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
            runtimeFactory: { StubDashboardRuntime() }
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
            runtimeFactory: { StubDashboardRuntime() }
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
                StubDashboardRuntime(compatibilityChecks: [unavailableRenderer])
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
                StubDashboardRuntime(compatibilityChecks: [compatibleRenderer])
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
        let coordinator = DashboardCoordinator(
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
        let coordinator = DashboardCoordinator(
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
    }

    func testUnreadPollingScheduleMatchesLatencyBounds() {
        XCTAssertEqual(DashboardPollingController.Schedule.unread(active: true), .milliseconds(500))
        XCTAssertEqual(DashboardPollingController.Schedule.unread(active: false), .seconds(1))
    }

    func testWorkingTreePollingScheduleIsOnlyAFallbackForFileEvents() {
        XCTAssertEqual(DashboardPollingController.Schedule.workingTree(active: true), .seconds(15))
        XCTAssertEqual(DashboardPollingController.Schedule.workingTree(active: false), .seconds(60))
    }

    func testUnreadFailureShowsWarningWithoutHidingCatalog() async {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let coordinator = DashboardCoordinator(
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

    func testNewTaskCompletionForegroundsCodexAfterInitialSnapshot() async {
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(id: "thread-1", runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(id: "thread-1", latestLifecycleEvent: completed)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let coordinator = DashboardCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()
        XCTAssertEqual(foregrounder.callCount, 0)
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 1)
    }

    func testInitialCompletedSnapshotDoesNotForegroundCodex() async {
        let foregrounder = RecordingCodexForegrounder()
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: .now)
        let coordinator = DashboardCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(
                    threads: [.fixture(latestLifecycleEvent: completed)],
                    totalThreadCount: 1
                )
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 0)
    }

    func testAbortedTaskDoesNotForegroundCodex() async {
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let aborted = ThreadLifecycleEvent(kind: .aborted, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(latestLifecycleEvent: aborted)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let coordinator = DashboardCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 0)
    }

    func testForegroundPreferencePersistsAndSuppressesCompletionActivation() async throws {
        let suiteName = "DashboardCoordinatorForegroundTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(latestLifecycleEvent: completed)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let coordinator = DashboardCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            userDefaults: defaults,
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )
        await coordinator.synchronizeDashboard()

        coordinator.foregroundOnTaskCompletion = false
        await coordinator.synchronizeDashboard()

        XCTAssertFalse(defaults.bool(forKey: DashboardCoordinator.foregroundOnTaskCompletionKey))
        XCTAssertEqual(foregrounder.callCount, 0)
    }

    func testCancelledSynchronizationCannotClearNewSynchronizationTask() async throws {
        let catalogProvider = SuspendedCatalogProvider()
        let coordinator = DashboardCoordinator(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
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
