import AppKit
import XCTest
@testable import CodexDashboard

@MainActor
final class AccountWindowPresenterTests: XCTestCase {
    func testLiveAccountWindowIsActuallyFrontmostWhenEnabled() async throws {
        guard let value = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_PRESENT_WINDOW"],
              let id = UUID(uuidString: value) else {
            throw XCTSkip("Set CODEX_DASHBOARD_PRESENT_WINDOW to a running account profile UUID to verify presentation.")
        }
        let profile = AccountWindowProfile(accountID: id)
        let application = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier)
            .first { CodexConfiguration.processArguments(for: $0.processIdentifier).map { profile.matches(processArguments: $0) } == true })
        try await AccountWindowPresenter().present(application, profile: profile, environment: profile.environment)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, application.processIdentifier)
    }
}
