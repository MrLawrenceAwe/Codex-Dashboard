import XCTest

@testable import CodexDashboard

@MainActor
final class CodexDashboardHostTests: XCTestCase {
    func testPreparingForRestartKeepsMaintenanceEnabled() throws {
        let host = try CodexDashboardHost()
        host.stopMaintainingDashboard()
        XCTAssertFalse(host.keepsDashboardMounted)

        host.prepareForRestart()

        XCTAssertTrue(host.keepsDashboardMounted)
    }
}
