import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testRestartLocksActionsDuringPreflightAndRejectsOverlappingRequest() async throws {
        let catalog = RestartPreflightCatalogProvider()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: catalog, observeFileChanges: false,
            runtimeFactory: { _ in runtime }
        )
        let restart = Task { await coordinator.restartCodexAndEnableDashboard() }
        try await waitUntil { await catalog.requestCount == 1 }

        XCTAssertTrue(coordinator.isPerformingAction)
        XCTAssertFalse(coordinator.dashboardActions.canRestart)
        await coordinator.restartCodexAndEnableDashboard()
        XCTAssertEqual(runtime.restartCallCount, 0)
        let preflightRequests = await catalog.requestCount
        XCTAssertEqual(preflightRequests, 1)

        await catalog.release()
        await restart.value
        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertFalse(coordinator.isPerformingAction)
    }

    func testRestartDrainsSynchronizationBeforeCheckingActiveChats() async throws {
        let catalog = RestartPreflightCatalogProvider()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: catalog, observeFileChanges: false,
            runtimeFactory: { _ in runtime }
        )
        let gate = RestartSynchronizationGate()
        let synchronization = Task {
            await coordinator.synchronizationCoalescer.perform { await gate.suspend() }
        }
        try await waitUntil { gate.started }
        let restart = Task { await coordinator.restartCodexAndEnableDashboard() }
        try await waitUntil { coordinator.isPerformingAction }

        let requestsBeforeDrain = await catalog.requestCount
        XCTAssertEqual(requestsBeforeDrain, 0)
        XCTAssertEqual(runtime.restartCallCount, 0)
        gate.release()
        await synchronization.value
        try await waitUntil { await catalog.requestCount == 1 }
        await catalog.release()
        await restart.value
        XCTAssertEqual(runtime.restartCallCount, 1)
    }

    func testRestartWaitsForInProgressBlockingCompatibilityCheck() async throws {
        let checker = RestartCompatibilityChecker()
        let catalog = RestartPreflightCatalogProvider()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: catalog, compatibilityChecker: checker,
            observeFileChanges: false, runtimeFactory: { _ in runtime }
        )
        let check = Task { await coordinator.checkCompatibility() }
        try await waitUntil { await checker.requestCount == 1 }
        let restart = Task { await coordinator.restartCodexAndEnableDashboard() }
        try await waitUntil { await catalog.requestCount == 1 }
        await catalog.release()
        var joinedCheckStarted = false
        var joinedCheckFinished = false
        let joinedCheck = Task {
            joinedCheckStarted = true
            await coordinator.checkCompatibility()
            joinedCheckFinished = true
        }
        try await waitUntil { joinedCheckStarted }
        XCTAssertFalse(joinedCheckFinished)
        XCTAssertEqual(runtime.restartCallCount, 0)
        await checker.release()
        await check.value
        await joinedCheck.value
        await restart.value

        let checkRequests = await checker.requestCount
        XCTAssertEqual(checkRequests, 1)
        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertEqual(coordinator.compatibilityReport?.blockingCount, 1)
        XCTAssertFalse(coordinator.isPerformingAction)
        XCTAssertFalse(coordinator.isCheckingCompatibility)
    }

    func testRestartRefusesToInterruptRunningTask() async {
        let runningThread = ThreadSummary(
            id: "running-thread",
            title: "Running",
            preview: "Working",
            projectName: "Project",
            checkoutPath: "/tmp/project",
            recencyEpochMillis: 1,
            isPinned: false,
            model: nil,
            runState: .running,
            latestLifecycleEvent: nil,
            projectGitStatus: .notRepository
        )
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [runningThread], totalThreadCount: 1)
            ),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            runtimeFactory: { _ in runtime }
        )

        await coordinator.restartCodexAndEnableDashboard()

        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertNil(coordinator.connectionError)
        XCTAssertEqual(coordinator.connectionNotice, "Finish or cancel active Codex chats before restarting.")
        XCTAssertFalse(coordinator.isPerformingAction)
    }

    func testMountedDashboardFailureIsReportedAsANotice() {
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(catalog: ThreadCatalog(threads: [], totalThreadCount: 0)),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            runtimeFactory: { _ in StubDashboardRuntime() }
        )

        coordinator.setFailure(
            DashboardError.enableFailed("A background snapshot could not be delivered."),
            lastKnownState: .dashboardMounted
        )

        XCTAssertNil(coordinator.connectionError)
        XCTAssertEqual(
            coordinator.connectionNotice,
            "Dashboard enablement failed: A background snapshot could not be delivered."
        )
        XCTAssertEqual(coordinator.statusPresentation.title, "Dashboard integration is live")
    }

    func testRestartDoesNotBypassBlockingCompatibilityReport() async {
        let incompatible = CompatibilityCheck(
            id: "sidebar-host",
            title: "Sidebar integration",
            status: .incompatible,
            detail: "Missing sidebar"
        )
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: [incompatible]),
            runtimeFactory: { _ in runtime }
        )
        await coordinator.checkCompatibility()

        await coordinator.restartCodexAndEnableDashboard()

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
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: checker,
            runtimeFactory: { _ in runtime }
        )
        await coordinator.checkCompatibility()

        await coordinator.restartCodexAndEnableDashboard()

        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertEqual(coordinator.compatibilityReport?.blockingCount, 0)
        XCTAssertNil(coordinator.connectionError)
    }

    func testCompatibilityCheckPublishesCapabilityReport() async {
        let expected = CompatibilityCheck(
            id: "storage",
            title: "Storage",
            status: .compatible,
            detail: "Healthy"
        )
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: [expected]),
            runtimeFactory: { _ in StubDashboardRuntime() }
        )

        await coordinator.checkCompatibility()

        XCTAssertEqual(coordinator.compatibilityReport?.checks, [expected])
        XCTAssertFalse(coordinator.isCheckingCompatibility)
    }

    func testVersionTriggeredCompatibilityWarningSendsOneNotification() async throws {
        let suiteName = "AppCoordinatorCompatibilityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1.0", forKey: "lastCheckedCodexVersion")
        let warning = CompatibilityCheck(
            id: "model-picker",
            title: "Model picker controls",
            status: .warning,
            detail: "Controls changed"
        )
        let notifier = RecordingCompatibilityIssueNotifier()
        let coordinator = makeAppCoordinator(
            compatibilityChecker: StubCompatibilityChecker(checks: [warning]),
            userDefaults: defaults,
            installedCodexVersion: { "2.0" },
            compatibilityIssueNotifier: notifier,
            runtimeFactory: { _ in StubDashboardRuntime(compatibilityChecks: [
                CompatibilityCheck(
                    id: "renderer",
                    title: "Renderer connection",
                    status: .compatible,
                    detail: "Renderer inspected."
                ),
            ]) }
        )
        coordinator.compatibilityWasTriggeredByUpdate = coordinator.compatibilityMonitor.updateWasDetected

        await coordinator.checkCompatibility()
        await coordinator.checkCompatibility()

        XCTAssertEqual(notifier.reports.count, 1)
        XCTAssertEqual(notifier.reports.first?.warningCount, 1)
    }

    func testVersionTriggeredCompatibleReportDoesNotSendNotification() async throws {
        let suiteName = "AppCoordinatorCompatibilityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1.0", forKey: "lastCheckedCodexVersion")
        let notifier = RecordingCompatibilityIssueNotifier()
        let coordinator = makeAppCoordinator(
            userDefaults: defaults,
            installedCodexVersion: { "2.0" },
            compatibilityIssueNotifier: notifier,
            runtimeFactory: { _ in StubDashboardRuntime(compatibilityChecks: [
                CompatibilityCheck(
                    id: "renderer",
                    title: "Renderer connection",
                    status: .compatible,
                    detail: "Renderer inspected."
                ),
            ]) }
        )
        coordinator.compatibilityWasTriggeredByUpdate = coordinator.compatibilityMonitor.updateWasDetected

        await coordinator.checkCompatibility()

        XCTAssertTrue(notifier.reports.isEmpty)
    }

    func testCompatibilityCheckAcknowledgesVersionOnlyAfterRendererInspection() async throws {
        let suiteName = "AppCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1.0", forKey: "lastCheckedCodexVersion")
        let unavailableRenderer = CompatibilityCheck(
            id: "renderer",
            title: "Renderer connection",
            status: .unavailable,
            detail: "Codex is closed."
        )
        let unavailableCoordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            userDefaults: defaults,
            installedCodexVersion: { "2.0" },
            runtimeFactory: { _ in
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
        let compatibleCoordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            projectGitStatusProvider: StubProjectGitStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            userDefaults: defaults,
            installedCodexVersion: { "2.0" },
            runtimeFactory: { _ in
                StubDashboardRuntime(compatibilityChecks: [compatibleRenderer])
            }
        )

        await compatibleCoordinator.checkCompatibility()
        XCTAssertEqual(defaults.string(forKey: "lastCheckedCodexVersion"), "2.0")
    }

}

private actor RestartPreflightCatalogProvider: ThreadCatalogProviding {
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
        requestCount += 1
        if requestCount == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        return ThreadCatalog(threads: [], totalThreadCount: 0)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RestartSynchronizationGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RestartCompatibilityChecker: LocalCompatibilityChecking {
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func checkLocalContracts() async -> [CompatibilityCheck] {
        requestCount += 1
        if requestCount == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        return [CompatibilityCheck(id: "storage", title: "Storage", status: .incompatible,
                                   detail: "Blocking preflight result.")]
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
