import XCTest

@testable import CodexDashboard

private struct StubCatalogProvider: ThreadCatalogProviding {
    let catalog: ThreadCatalog

    func loadCatalog(
        workingTreeStatuses: [String: WorkingTreeStatus],
        codexLaunchDate: Date?
    ) async throws -> ThreadCatalog {
        catalog
    }
}

private struct StubWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    func load(projectPaths: Set<String>) async -> [String: WorkingTreeStatus] {
        [:]
    }
}

private struct StubUnreadIDProvider: UnreadThreadIDProviding {
    let unreadThreadIDs: Set<String>

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
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

    func loadCatalog(
        workingTreeStatuses: [String: WorkingTreeStatus],
        codexLaunchDate: Date?
    ) async -> ThreadCatalog {
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
private final class StubDashboardRuntime: DashboardRuntime {
    let codexIsRunning = false
    let codexLaunchDate: Date? = nil
    let maintainsDashboard = false

    func rendererTargets() async -> [DevToolsTarget] { [] }
    func prepareForRestart() {}
    func restartCodex() async throws -> [DevToolsTarget] { [] }
    func synchronizeDashboard(
        with snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws {}
    func disableThreadDashboard() async throws -> DashboardDisableOutcome { .codexClosed }
    func openThreadDashboard() async {}
    func rendererCompatibilityChecks() async -> [CompatibilityCheck] { [] }
}

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testCompatibilityCheckPublishesCapabilityReport() async {
        let expected = CompatibilityCheck(
            id: "storage",
            title: "Storage",
            status: .compatible,
            detail: "Healthy"
        )
        let viewModel = DashboardViewModel(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: [expected]),
            runtimeFactory: { StubDashboardRuntime() }
        )

        await viewModel.checkCompatibility()

        XCTAssertEqual(viewModel.compatibilityReport?.checks, [expected])
        XCTAssertFalse(viewModel.isCheckingCompatibility)
    }

    func testSynchronizationUsesInjectedDependenciesWithoutStartingPolling() async {
        let thread = ThreadSummary.fixture(id: "thread-1", title: "Injected thread")
        let viewModel = DashboardViewModel(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 4)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: [thread.id]),
            runtimeFactory: { StubDashboardRuntime() }
        )

        XCTAssertEqual(viewModel.connectionState, .checking)
        await viewModel.synchronizeDashboard()

        XCTAssertTrue(viewModel.threads.first?.isUnread == true)
        XCTAssertEqual(viewModel.totalThreadCount, 4)
        XCTAssertEqual(viewModel.connectionState, .codexClosed)
        XCTAssertEqual(viewModel.statusPresentation.title, "Codex is closed")
    }

    func testUnreadPollingUpdatesThreadWithinBoundedInterval() async throws {
        let thread = ThreadSummary.fixture(id: "thread-1")
        let unreadIDProvider = MutableUnreadIDProvider()
        let viewModel = DashboardViewModel(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadIDProvider: unreadIDProvider,
            runtimeFactory: { StubDashboardRuntime() }
        )
        viewModel.startMonitoring()
        defer { viewModel.stopMonitoring() }

        try await waitUntil { viewModel.threads.count == 1 }
        await unreadIDProvider.setUnreadThreadIDs([thread.id])
        try await waitUntil { viewModel.threads.first?.isUnread == true }

        XCTAssertTrue(viewModel.threads.first?.isUnread == true)
    }

    func testCancelledSynchronizationCannotClearNewSynchronizationTask() async throws {
        let catalogProvider = SuspendedCatalogProvider()
        let viewModel = DashboardViewModel(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            runtimeFactory: { StubDashboardRuntime() }
        )

        viewModel.startMonitoring()
        try await waitUntil { await catalogProvider.count() == 1 }
        viewModel.stopMonitoring()
        viewModel.startMonitoring()
        try await waitUntil { await catalogProvider.count() == 2 }

        await catalogProvider.resumeNext()
        try await Task.sleep(for: .milliseconds(50))
        let coalescedRefresh = Task { @MainActor in await viewModel.synchronizeDashboard() }
        try await Task.sleep(for: .milliseconds(50))
        let requestCount = await catalogProvider.count()
        XCTAssertEqual(requestCount, 2)

        await catalogProvider.resumeNext()
        await coalescedRefresh.value
        viewModel.stopMonitoring()
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
