import XCTest

@testable import CodexDashboard

@MainActor
final class CodexHostSessionTests: XCTestCase {
    func testPreparingForRestartKeepsMaintenanceEnabled() throws {
        let session = try CodexHostSession()
        session.stopMaintainingDashboard()
        XCTAssertFalse(session.keepsDashboardMounted)

        session.prepareForRestart()

        XCTAssertTrue(session.keepsDashboardMounted)
    }
}
