import XCTest

@testable import CodexDashboard

@MainActor
final class AppCoordinatorRecoveryTests: XCTestCase {
    private var warning: CompatibilityCheck {
        CompatibilityCheck(id: "model-picker", title: "Model settings controls", status: .warning, detail: "Controls missing")
    }

    func testMountedDashboardWithWarningTriggersBackgroundRestart() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true, compatibilityChecks: [warning])
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        await coordinator.checkCompatibility()
        coordinator.connectionState = .dashboardMounted

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(runtime.restartActivations, [false])
        XCTAssertEqual(coordinator.automaticRestartAttempts, 1)
    }

    func testPersistentWarningStopsAtThreeDespiteSuccessfulMounts() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true, compatibilityChecks: [warning])
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        await coordinator.checkCompatibility()
        coordinator.connectionState = .dashboardMounted
        for _ in 0..<8 { await coordinator.synchronizeDashboard() }

        XCTAssertEqual(runtime.restartActivations, [false, false, false])
        XCTAssertEqual(coordinator.automaticRestartAttempts, 3)
        XCTAssertEqual(coordinator.connectionNotice, AppCoordinator.automaticRecoveryLimitMessage)
    }

    func testWarningClearedByFreshPreflightCheckDoesNotRestartHealthyMount() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        coordinator.connectionState = .dashboardMounted
        coordinator.compatibilityReport = CompatibilityReport(checks: [warning])
        coordinator.automaticRestartAttempts = 2

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertEqual(coordinator.compatibilityReport?.nonBlockingAttentionCount, 0)
        XCTAssertEqual(coordinator.automaticRestartAttempts, 0)
    }

    func testPostRestartWarningCheckMustBeHealthyBeforeResettingBudget() async {
        let checker = SequencedCompatibilityChecker(results: [[warning], [warning], []])
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(compatibilityChecker: checker, runtimeFactory: { _ in runtime })
        await coordinator.checkCompatibility()
        coordinator.connectionState = .dashboardMounted
        coordinator.automaticRestartAttempts = 2

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertEqual(coordinator.compatibilityReport?.nonBlockingAttentionCount, 0)
        XCTAssertEqual(coordinator.automaticRestartAttempts, 0)
        XCTAssertNil(coordinator.connectionNotice)
    }

    func testUnavailableCompatibilityCheckAlsoTriggersBoundedRecovery() async {
        let unavailable = CompatibilityCheck(id: "renderer", title: "Renderer", status: .unavailable, detail: "Connection lost")
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true, compatibilityChecks: [unavailable])
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        await coordinator.checkCompatibility()
        for _ in 0..<5 { await coordinator.synchronizeDashboard() }
        XCTAssertEqual(runtime.restartCallCount, 3)
    }

    func testChatStartingDuringWarningPreflightPreventsRestart() async {
        let catalog = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(threads: [], totalThreadCount: 0),
            ThreadCatalog(threads: [.fixture(id: "newly-running", runState: .running)], totalThreadCount: 1),
        ])
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true, compatibilityChecks: [warning])
        let coordinator = makeAppCoordinator(catalogProvider: catalog, runtimeFactory: { _ in runtime })
        coordinator.connectionState = .dashboardMounted
        coordinator.compatibilityReport = CompatibilityReport(checks: [warning])

        await coordinator.recoverDashboardIfNeeded()

        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertEqual(coordinator.automaticRestartAttempts, 0)
        XCTAssertEqual(coordinator.connectionNotice, "Finish or cancel active Codex chats before restarting.")
    }

    func testMissingDashboardRecoversInBackgroundThroughNormalSynchronization() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        // An enabled integration with no renderer models a normal Codex launch.
        runtime.targetsAreAvailable = false
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(runtime.restartActivations, [false])
        XCTAssertEqual(coordinator.connectionState, .dashboardMounted)
    }

    func testFailedMountStopsAfterThreeActualRestartsAcrossPolls() async {
        let runtime = StubDashboardRuntime(
            codexIsRunning: true, maintainsDashboard: true,
            synchronizationError: DashboardError.mountFailed("Mount warning")
        )
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        for _ in 0..<6 { await coordinator.synchronizeDashboard() }

        XCTAssertEqual(runtime.restartActivations, [false, false, false])
        XCTAssertEqual(coordinator.automaticRestartAttempts, 3)
        XCTAssertTrue(coordinator.connectionNotice?.contains("3 restart attempts") == true)
    }

    func testSuccessfulMountResetsBudgetAndClearsWarning() async {
        let runtime = StubDashboardRuntime(
            codexIsRunning: true, maintainsDashboard: true,
            synchronizationError: DashboardError.mountFailed("Mount warning")
        )
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        for _ in 0..<3 { await coordinator.synchronizeDashboard() }
        runtime.synchronizationError = nil
        await coordinator.synchronizeDashboard()
        XCTAssertEqual(coordinator.automaticRestartAttempts, 0)
        XCTAssertNil(coordinator.connectionNotice)

        runtime.synchronizationError = DashboardError.mountFailed("New failure")
        await coordinator.synchronizeDashboard()
        XCTAssertEqual(runtime.restartCallCount, 4)
    }

    func testForegroundCodexIsNeverRestartedAutomatically() async {
        let foregrounder = RecordingCodexForegrounder()
        foregrounder.isCodexFrontmost = true
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(codexForegrounder: foregrounder, runtimeFactory: { _ in runtime })
        coordinator.connectionState = .dashboardMounted
        coordinator.compatibilityReport = CompatibilityReport(checks: [warning])
        await coordinator.recoverDashboardIfNeeded()
        XCTAssertEqual(runtime.restartCallCount, 0)
    }

    func testRunningChatDetectedDuringPreflightPreventsRestart() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let catalog = StubCatalogProvider(catalog: ThreadCatalog(
            threads: [.fixture(id: "running", runState: .running)], totalThreadCount: 1
        ))
        let coordinator = makeAppCoordinator(catalogProvider: catalog, runtimeFactory: { _ in runtime })
        await coordinator.recoverDashboardIfNeeded()
        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertEqual(coordinator.automaticRestartAttempts, 0)
    }

    func testCodexBecomingForegroundDuringPreflightPreventsRestart() async {
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        runtime.onWaitForReviewOperations = { foregrounder.isCodexFrontmost = true }
        let coordinator = makeAppCoordinator(codexForegrounder: foregrounder, runtimeFactory: { _ in runtime })
        await coordinator.recoverDashboardIfNeeded()
        XCTAssertEqual(runtime.restartCallCount, 0)
    }

    func testBlockingCompatibilityPreventsRestart() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        coordinator.compatibilityReport = CompatibilityReport(checks: [CompatibilityCheck(
            id: "blocked", title: "Blocked", status: .incompatible, detail: "Contract changed"
        )])
        await coordinator.recoverDashboardIfNeeded()
        XCTAssertEqual(runtime.restartCallCount, 0)
    }

    func testActivityMustBeCheckableBeforeRestart() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(catalogProvider: FailingRecoveryCatalogProvider(), runtimeFactory: { _ in runtime })
        await coordinator.recoverDashboardIfNeeded()
        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertNotNil(coordinator.connectionError)
    }

    func testClosedCodexDisabledIntegrationAndSpeechInputPreventRecovery() async {
        let runtime = StubDashboardRuntime(codexIsRunning: false, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        await coordinator.recoverDashboardIfNeeded()
        runtime.codexIsRunning = true
        runtime.maintainsDashboard = false
        await coordinator.recoverDashboardIfNeeded()
        runtime.maintainsDashboard = true
        runtime.speechInputIsActive = true
        await coordinator.recoverDashboardIfNeeded()
        XCTAssertEqual(runtime.restartCallCount, 0)
    }

    func testManualRestartResetsExhaustedBudgetAndActivatesCodex() async {
        let runtime = StubDashboardRuntime(codexIsRunning: true, maintainsDashboard: true)
        let coordinator = makeAppCoordinator(runtimeFactory: { _ in runtime })
        coordinator.automaticRestartAttempts = 3
        await coordinator.restartCodexAndEnableDashboard()
        XCTAssertEqual(runtime.restartActivations, [true])
        XCTAssertEqual(coordinator.automaticRestartAttempts, 0)
    }
}

private struct FailingRecoveryCatalogProvider: ThreadCatalogProviding {
    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async throws -> ThreadCatalog {
        throw DashboardError.mountFailed("Cannot read chat activity")
    }
}
