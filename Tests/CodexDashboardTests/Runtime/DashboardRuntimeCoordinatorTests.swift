import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardRuntimeCoordinatorTests: XCTestCase {
    func testPreparingForRestartRestoresMaintenance() throws {
        let runtime = try DashboardRuntimeCoordinator()
        runtime.stopMaintainingDashboard()
        XCTAssertFalse(runtime.maintainsDashboard)

        runtime.prepareForRestart()

        XCTAssertTrue(runtime.maintainsDashboard)
    }
}
