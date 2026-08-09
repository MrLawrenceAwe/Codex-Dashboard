import XCTest

@testable import CodexDashboard

final class CodexVersionCompatibilityTrackerTests: XCTestCase {
    func testDetectsOnlyAChangeFromPreviouslyCheckedVersion() throws {
        let suiteName = "CodexVersionCompatibilityTrackerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tracker = CodexVersionCompatibilityTracker(userDefaults: defaults)

        XCTAssertFalse(tracker.updateWasDetected(currentVersion: "1"))
        tracker.markChecked(version: "1")
        XCTAssertFalse(tracker.updateWasDetected(currentVersion: "1"))
        XCTAssertTrue(tracker.updateWasDetected(currentVersion: "2"))
    }
}
