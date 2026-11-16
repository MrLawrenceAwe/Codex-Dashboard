import XCTest
@testable import CodexDashboard

@MainActor
final class AccountWindowRuntimeContextTests: XCTestCase {
    func testReplacesConnectionWhenSharedModeOrDebugPortChanges() {
        let profile = AccountWindowProfile(accountID: UUID())
        let context = AccountWindowRuntimeContext(profile: profile, arguments: "Codex --remote-debugging-port=50123")
        XCTAssertTrue(context.matches(arguments: "Codex --remote-debugging-port=50123", sharedChats: context.sharedChats))
        XCTAssertFalse(context.matches(arguments: "Codex --remote-debugging-port=50124", sharedChats: context.sharedChats))
        XCTAssertFalse(context.matches(arguments: "Codex --remote-debugging-port=50123", sharedChats: !context.sharedChats))
    }
}
