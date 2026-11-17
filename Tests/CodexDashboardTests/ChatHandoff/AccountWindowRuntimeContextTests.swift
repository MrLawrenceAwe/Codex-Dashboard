import XCTest
@testable import CodexDashboard

@MainActor
final class AccountWindowRuntimeContextTests: XCTestCase {
    func testReplacesConnectionWhenDebugPortChanges() {
        let profile = AccountWindowProfile(accountID: UUID())
        let context = AccountWindowRuntimeContext(profile: profile, arguments: "Codex --remote-debugging-port=50123")
        XCTAssertTrue(context.matches(arguments: "Codex --remote-debugging-port=50123"))
        XCTAssertFalse(context.matches(arguments: "Codex --remote-debugging-port=50124"))
    }
}
