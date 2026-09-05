import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardStatusItemControllerTests: XCTestCase {
    func testStatusIconStaysFilledForAnEnabledDashboardWithAnAvailableRenderer() {
        XCTAssertTrue(
            DashboardConnectionState.rendererAvailable.statusIconIsFilled(
                dashboardMaintenanceIsEnabled: true
            )
        )
        XCTAssertFalse(
            DashboardConnectionState.rendererAvailable.statusIconIsFilled(
                dashboardMaintenanceIsEnabled: false
            )
        )
    }

    func testCompatibilityFindingsReplaceTheNormalStatusIcon() {
        let warning = CompatibilityReport(checks: [CompatibilityCheck(
            id: "composer",
            title: "Composer",
            status: .warning,
            detail: "Changed"
        )])
        let incompatible = CompatibilityReport(checks: [CompatibilityCheck(
            id: "renderer",
            title: "Renderer",
            status: .incompatible,
            detail: "Broken"
        )])

        XCTAssertEqual(
            DashboardStatusItemController.statusSymbolName(
                for: .dashboardMounted,
                report: warning,
                dashboardMaintenanceIsEnabled: true
            ),
            "exclamationmark.triangle.fill"
        )
        XCTAssertEqual(
            DashboardStatusItemController.statusSymbolName(
                for: .dashboardMounted,
                report: incompatible,
                dashboardMaintenanceIsEnabled: true
            ),
            "exclamationmark.octagon.fill"
        )
        XCTAssertTrue(DashboardStatusItemController.requiresCompatibilityAttention(warning))
        XCTAssertEqual(warning.attentionSummary, "Composer: Changed")
    }

    private let positionKey = "NSStatusItem Preferred Position CodexDashboardStatusItem"

    func testRegistersVisibleDefaultStatusItemPosition() throws {
        let defaults = try makeDefaults()

        DashboardStatusItemController.registerDefaultPosition(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: positionKey), 450)
    }

    func testPreservesUserSelectedStatusItemPosition() throws {
        let defaults = try makeDefaults()
        defaults.set(720, forKey: positionKey)

        DashboardStatusItemController.registerDefaultPosition(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: positionKey), 720)
    }

    func testDashboardActionAvailabilityIsSharedAcrossPresentations() {
        let mounted = DashboardActionPresentation(
            connectionState: .dashboardMounted,
            isPerformingAction: false,
            isCheckingCompatibility: false
        )
        XCTAssertTrue(mounted.canOpen)
        XCTAssertTrue(mounted.canRestart)
        XCTAssertTrue(mounted.canDisable)

        let checking = DashboardActionPresentation(
            connectionState: .codexClosed,
            isPerformingAction: false,
            isCheckingCompatibility: true
        )
        XCTAssertFalse(checking.canOpen)
        XCTAssertFalse(checking.canRestart)
        XCTAssertFalse(checking.canDisable)

        let busy = DashboardActionPresentation(
            connectionState: .rendererAvailable,
            isPerformingAction: true,
            isCheckingCompatibility: false
        )
        XCTAssertFalse(busy.canOpen)
        XCTAssertFalse(busy.canRestart)
        XCTAssertFalse(busy.canDisable)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "DashboardStatusItemControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
