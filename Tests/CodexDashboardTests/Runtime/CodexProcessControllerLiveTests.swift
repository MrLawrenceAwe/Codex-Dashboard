import AppKit
import XCTest

@testable import CodexDashboard

@MainActor
final class CodexProcessControllerLiveTests: XCTestCase {
    func testAccountWindowCanQuitGracefullyAndReconnectThroughProductionController() async throws {
        guard let scope = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_RESTART_ACCOUNT"],
              let accountID = UUID(uuidString: scope) else {
            throw XCTSkip("Requires an explicitly selected separate account window.")
        }
        let profile = AccountWindowProfile(accountID: accountID)
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier)
            .filter {
                guard let arguments = CodexConfiguration.processArguments(for: $0.processIdentifier) else { return false }
                return profile.matches(processArguments: arguments)
            }
        XCTAssertEqual(applications.count, 1)
        let original = try XCTUnwrap(applications.first)
        let arguments = try XCTUnwrap(CodexConfiguration.processArguments(for: original.processIdentifier))
        let port = try XCTUnwrap(CodexConfiguration.devToolsPort(inProcessArguments: arguments))
        var reopened: NSRunningApplication?
        var preparedAfterQuit = false
        let controller = CodexProcessController(
            runningApplicationsProvider: { original.isTerminated ? [] : [original] },
            applicationLauncher: { url, configuration in
                reopened = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            },
            makeLaunchConfiguration: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["--user-data-dir=" + profile.desktopData.path]
                    + CodexConfiguration.debugArguments(port: port)
                configuration.environment = [
                    "CODEX_HOME": profile.codexHome.path,
                    "CODEX_ELECTRON_USER_DATA_PATH": profile.desktopData.path,
                ]
                return configuration
            }
        )

        try await controller.restart(activate: false, beforeLaunch: {
            XCTAssertTrue(original.isTerminated)
            preparedAfterQuit = true
        })

        XCTAssertTrue(preparedAfterQuit)
        XCTAssertNotEqual(reopened?.processIdentifier, original.processIdentifier)
        let client = DevToolsClient(portProvider: { port })
        let deadline = ContinuousClock.now + .seconds(30)
        while await client.mainRendererTargets().isEmpty {
            guard ContinuousClock.now < deadline else { return XCTFail("Restarted window did not reconnect") }
            try await Task.sleep(for: .milliseconds(350))
        }
        await client.disconnect()
    }
}
