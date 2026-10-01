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
              "identity": {
                "local:one": ["thread-one", "thread-two"],
                "remote:one": ["cloud-thread"]
              }
            }
          }
        }
        """
        try Data(state.utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let unreadThreadIDs = try await CodexUnreadThreadIDProvider(stateURL: stateURL, identityKeyLoader: { "identity" })
            .loadUnreadThreadIDs()

        XCTAssertEqual(unreadThreadIDs, ["thread-one", "thread-two"])
    }

    func testUnreadStateIsScopedToTheActiveIdentity() throws {
        let state = Data(#"{"electron-thread-read-state-v1":{"unreadByIdentity":{"first":{"local:host":["old-unread"]},"second":{"local:host":[],"remote:host":["remote-unread"]}}}}"#.utf8)
        XCTAssertEqual(try CodexUnreadThreadIDProvider.decodeUnreadThreadIDs(
            from: state, identityKey: "first"), ["old-unread"])
        XCTAssertEqual(try CodexUnreadThreadIDProvider.decodeUnreadThreadIDs(
            from: state, identityKey: "second"), [])
        XCTAssertEqual(try CodexUnreadThreadIDProvider.decodeUnreadThreadIDs(
            from: state, identityKey: "unknown"), [])
        XCTAssertEqual(try CodexUnreadThreadIDProvider.decodeUnreadThreadIDs(
            from: state, identityKey: nil), [])
    }

    func testAccountSwitchInvalidatesCacheWithoutGlobalStateChange() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-switch-\(UUID().uuidString).json")
        let identityURL = stateURL.appendingPathExtension("identity")
        try Data(#"{"electron-thread-read-state-v1":{"unreadByIdentity":{"first":{"local:host":["old-unread"]},"second":{"local:host":[]}}}}"#.utf8).write(to: stateURL)
        try Data("first".utf8).write(to: identityURL)
        defer {
            try? FileManager.default.removeItem(at: stateURL)
            try? FileManager.default.removeItem(at: identityURL)
        }
        let loader = CountingStateLoader()
        let provider = CodexUnreadThreadIDProvider(stateURL: stateURL, identityKeyLoader: {
            try String(contentsOf: identityURL, encoding: .utf8)
        }, dataLoader: loader.load)
        let first = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(first, ["old-unread"])
        try Data("second".utf8).write(to: identityURL)
        let second = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(second, [])
        XCTAssertEqual(loader.loadCount, 2)
    }

    func testIdentityKeyMatchesCodexPrincipalHash() throws {
        let claims = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-one","chatgpt_user_id":"user-one"}}"#.utf8)
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let credential = try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "header.\(payload).signature"],
        ])
        XCTAssertEqual(try CodexUnreadThreadIDProvider.identityKey(from: credential),
                       "9125e93f0b5dcba925ea6b5b25b5b0bd4b4e4a9f4d6ea9400e4a209fe72c07a9")
        XCTAssertNil(try CodexUnreadThreadIDProvider.identityKey(from: Data("{}".utf8)))
    }

    func testReportsInvalidGlobalState() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-invalid-global-state-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        do {
            _ = try await CodexUnreadThreadIDProvider(stateURL: stateURL, identityKeyLoader: { "identity" }).loadUnreadThreadIDs()
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
        let provider = CodexUnreadThreadIDProvider(stateURL: stateURL, identityKeyLoader: { "identity" }, dataLoader: loader.load)

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
        let provider = CodexUnreadThreadIDProvider(stateURL: stateURL, identityKeyLoader: { "identity" })

        let initialUnreadThreadIDs = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(initialUnreadThreadIDs, ["one"])
        try Data(secondState.utf8).write(to: stateURL)

        let updatedUnreadThreadIDs = try await provider.loadUnreadThreadIDs()
        XCTAssertEqual(updatedUnreadThreadIDs, ["two"])
    }
}
