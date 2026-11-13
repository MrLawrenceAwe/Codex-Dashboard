import XCTest

@testable import CodexDashboard

@MainActor
final class AccountPopoverBridgeTests: XCTestCase {
    func testCompletionIsReplayableWhileDiscoveringTargets() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: "app://-/index.html",
                                    webSocketURL: "ws://127.0.0.1/main")
        let action = AccountPopoverAction(requestID: "completed", kind: .restartForSignIn, accountID: nil)
        let devTools = AccountPopoverRendererDevTools(
            target: target, action: String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        )
        let bridge = AccountPopoverBridge(devTools: devTools)
        let snapshot = AccountPopoverSnapshot(accounts: [], activeAccountID: nil,
                                             statusMessage: nil, isBusy: false, usageBlockage: nil)
        var replayResult: AccountPopoverActionPollResult?
        await bridge.complete(action, snapshot: snapshot, targets: {
            // Target discovery may suspend while the poller sees the same request.
            replayResult = await bridge.poll(in: [target], isEnabled: { true })
            return []
        })
        XCTAssertEqual(replayResult, .empty)
        let attempts = await devTools.completionAttempts
        XCTAssertEqual(attempts, 1)
    }
}
