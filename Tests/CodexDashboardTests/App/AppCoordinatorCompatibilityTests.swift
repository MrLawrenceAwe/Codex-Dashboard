import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testRestartRefusesToInterruptRunningTask() async {
        let runningThread = ThreadSummary(
            id: "running-thread",
            title: "Running",
            preview: "Working",
            projectName: "Project",
            projectPath: "/tmp/project",
            recencyEpochMillis: 1,
            isPinned: false,
            model: nil,
            runState: .running,
            latestLifecycleEvent: nil,
            workingTreeStatus: .notRepository
        )
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [runningThread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            runtimeFactory: { _ in runtime }
        )

        await coordinator.restartCodexAndEnableDashboard()

        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertNil(coordinator.connectionError)
        XCTAssertEqual(coordinator.connectionNotice, "Finish or cancel active Codex tasks before restarting.")
    }

    func testMountedDashboardFailureIsReportedAsANotice() {
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(catalog: ThreadCatalog(threads: [], totalThreadCount: 0)),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
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
        XCTAssertEqual(coordinator.statusPresentation.title, "Task Dashboard is live")
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
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
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
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
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
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
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
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
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
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
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
