import XCTest

@testable import CodexDashboard

final class AppConfigurationTests: XCTestCase {
    func testHostLaunchTargetsApplicationBundleThroughLaunchServices() {
        XCTAssertEqual(
            AppConfiguration.hostApplicationURL.path,
            "/Applications/ChatGPT.app"
        )
        XCTAssertEqual(
            AppConfiguration.hostLaunchArguments,
            [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=47832",
                "--remote-allow-origins=http://localhost",
            ]
        )
    }
}
