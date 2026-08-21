import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardStatusItemControllerTests: XCTestCase {
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

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "DashboardStatusItemControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
