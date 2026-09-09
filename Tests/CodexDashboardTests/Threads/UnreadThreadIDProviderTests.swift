import Foundation
import XCTest

@testable import CodexDashboard

private final class CountingStateLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var loadCount: Int {
        lock.withLock { count }
    }

    func load(_ url: URL) throws -> Data {
        lock.lock()
        count += 1
        lock.unlock()
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

final class UnreadThreadIDProviderTests: XCTestCase {
    func testLoadsLocalUnreadThreadIDsFromGlobalState() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-global-state-\(UUID().uuidString).json")
        let state = """
        {
          "electron-thread-read-state-v1": {
            "unreadByIdentity": {
              "identity-one": {
                "local:one": ["thread-one", "thread-two"],
                "remote:one": ["cloud-thread"]
              }
            }
          }
        }
        """
        try Data(state.utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let unreadThreadIDs = try await CodexUnreadThreadIDProvider(stateURL: stateURL)
            .loadUnreadThreadIDs()

        XCTAssertEqual(unreadThreadIDs, ["thread-one", "thread-two"])
    }

    func testReportsInvalidGlobalState() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-invalid-global-state-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        do {
            _ = try await CodexUnreadThreadIDProvider(stateURL: stateURL).loadUnreadThreadIDs()
            XCTFail("Expected invalid global state to be reported")
        } catch UnreadThreadIDError.invalidState(let invalidURL) {
            XCTAssertEqual(invalidURL, stateURL)
        }
    }

    func testReusesDecodedStateWhileFileSignatureIsUnchanged() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-cached-global-state-\(UUID().uuidString).json")
        let state = #"{"electron-thread-read-state-v1":{"unreadByIdentity":{"identity":{"local:one":["thread-one"]}}}}"#
        try Data(state.utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }
        let loader = CountingStateLoader()
        let provider = CodexUnreadThreadIDProvider(stateURL: stateURL, dataLoader: loader.load)

        let initialUnreadThreadIDs = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(initialUnreadThreadIDs, ["thread-one"])
        let cachedUnreadThreadIDs = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(cachedUnreadThreadIDs, ["thread-one"])
        XCTAssertEqual(loader.loadCount, 1)
    }

    func testReloadsDecodedStateWhenFileSignatureChanges() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-updated-global-state-\(UUID().uuidString).json")
        let firstState = #"{"electron-thread-read-state-v1":{"unreadByIdentity":{"identity":{"local:one":["one"]}}}}"#
        let secondState = #"{"electron-thread-read-state-v1":{"unreadByIdentity":{"identity":{"local:one":["two"]}}}}"#
        try Data(firstState.utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }
        let provider = CodexUnreadThreadIDProvider(stateURL: stateURL)

        let initialUnreadThreadIDs = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(initialUnreadThreadIDs, ["one"])
        try Data(secondState.utf8).write(to: stateURL)

        let updatedUnreadThreadIDs = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(updatedUnreadThreadIDs, ["two"])
    }
}
