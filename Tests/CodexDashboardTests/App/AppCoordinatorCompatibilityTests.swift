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
        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [runningThread], totalThreadCount: 1)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            runtimeFactory: { runtime }
        )

        await coordinator.restartCodexAndEnableThreadDashboard()

        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertEqual(
            coordinator.connectionError,
            "Finish or cancel active Codex tasks before restarting."
        )
    }

    func testRestartDoesNotBypassBlockingCompatibilityReport() async {
        let incompatible = CompatibilityCheck(
            id: "sidebar-host",
            title: "Sidebar integration",
            status: .incompatible,
            detail: "Missing sidebar"
        )
        let runtime = StubDashboardRuntime()
        let coordinator = AppCoordinator(
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
        let coordinator = AppCoordinator(
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

    func testCompatibilityCheckPublishesCapabilityReport() async {
        let expected = CompatibilityCheck(
            id: "storage",
            title: "Storage",
            status: .compatible,
            detail: "Healthy"
        )
        let coordinator = AppCoordinator(
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
        let unavailableCoordinator = AppCoordinator(
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
        let compatibleCoordinator = AppCoordinator(
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

}
