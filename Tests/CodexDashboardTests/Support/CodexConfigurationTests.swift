import XCTest

@testable import CodexDashboard

final class CodexConfigurationTests: XCTestCase {
    func testCodexLaunchConfiguration() {
        XCTAssertEqual(
            CodexConfiguration.codexApplicationURL.path,
            "/Applications/ChatGPT.app"
        )
        XCTAssertTrue((49_152...65_535).contains(CodexConfiguration.devToolsPort))
        XCTAssertEqual(
            CodexConfiguration.launchArguments,
            [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=\(CodexConfiguration.devToolsPort)",
                "--remote-allow-origins=http://localhost",
            ]
        )
    }
}
