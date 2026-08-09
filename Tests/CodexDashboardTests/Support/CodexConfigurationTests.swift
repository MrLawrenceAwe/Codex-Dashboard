import XCTest

@testable import CodexDashboard

final class CodexConfigurationTests: XCTestCase {
    func testCodexLaunchConfiguration() {
        XCTAssertEqual(
            CodexConfiguration.codexApplicationURL.path,
            "/Applications/ChatGPT.app"
        )
        XCTAssertEqual(
            CodexConfiguration.launchArguments,
            [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=47832",
                "--remote-allow-origins=http://localhost",
            ]
        )
    }
}
