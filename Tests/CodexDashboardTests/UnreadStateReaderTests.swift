import Foundation
import XCTest

@testable import CodexDashboard

final class UnreadStateReaderTests: XCTestCase {
    func testLoadsLocalUnreadThreadIDsFromGlobalState() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-global-state-\(UUID().uuidString).json")
        let state = """
        {
          "electron-persisted-atom-state": {
            "unread-thread-ids-by-host-v1": {
              "local": ["thread-one", "thread-two"],
              "cloud": ["cloud-thread"]
            }
          }
        }
        """
        try Data(state.utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let unreadThreadIDs = try await CodexUnreadStateReader(stateURL: stateURL)
            .loadUnreadThreadIDs()

        XCTAssertEqual(unreadThreadIDs, ["thread-one", "thread-two"])
    }

    func testReportsInvalidGlobalState() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-invalid-global-state-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        do {
            _ = try await CodexUnreadStateReader(stateURL: stateURL).loadUnreadThreadIDs()
            XCTFail("Expected invalid global state to be reported")
        } catch UnreadStateError.invalidState(let invalidURL) {
            XCTAssertEqual(invalidURL, stateURL)
        }
    }
}
