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

    func testReadsDevToolsPortFromRunningCodexArguments() {
        XCTAssertEqual(
            CodexConfiguration.devToolsPort(inProcessArguments:
                "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT "
                    + "--remote-debugging-address=127.0.0.1 "
                    + "--remote-debugging-port=61234"
            ),
            61_234
        )
        XCTAssertNil(CodexConfiguration.devToolsPort(inProcessArguments:
            "ChatGPT --remote-debugging-port=70000"
        ))
    }
}
