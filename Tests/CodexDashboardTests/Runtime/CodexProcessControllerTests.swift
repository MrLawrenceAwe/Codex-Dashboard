import AppKit
import XCTest

@testable import CodexDashboard

@MainActor
private final class StubRunningCodexApplication: RunningCodexApplication {
    let launchDate: Date? = .now
    var isRunning = true
    var isTerminated: Bool { !isRunning }
    private(set) var terminateCallCount = 0
    private(set) var forceTerminateCallCount = 0
    var exitsGracefully = false
    var exitsWhenForced = true

    func terminate() -> Bool {
        terminateCallCount += 1
        if exitsGracefully { isRunning = false }
        return true
    }

    func forceTerminate() -> Bool {
        forceTerminateCallCount += 1
        if exitsWhenForced { isRunning = false }
        return true
    }
}

@MainActor
final class CodexProcessControllerTests: XCTestCase {
    func testAccountSwitchDoesNotChangeCredentialsWhenAnotherWindowOpensDuringQuit() async throws {
        let original = StubRunningCodexApplication()
        original.exitsGracefully = true
        let replacement = StubRunningCodexApplication()
        var changedCredentials = false
        var launched = false
        let controller = CodexProcessController(
            applicationURL: URL(fileURLWithPath: "/Applications"),
            runningApplicationsProvider: { original.isRunning ? [original] : [replacement] },
            applicationLauncher: { _, _ in launched = true },
            sleep: { _ in }
        )

        do {
            try await controller.restart(beforeLaunch: { changedCredentials = true })
            XCTFail("Expected the switch to stop when another process appeared")
        } catch {
            guard case DashboardError.codexQuitTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertFalse(changedCredentials)
        XCTAssertFalse(launched)
        XCTAssertEqual(replacement.terminateCallCount, 0)
    }

    func testAccountSwitchWaitsForSlowGracefulQuitBeforeChangingCredentials() async throws {
        let application = StubRunningCodexApplication()
        var polls = 0
        var events: [String] = []
        let controller = CodexProcessController(
            applicationURL: URL(fileURLWithPath: "/Applications"),
            runningApplicationsProvider: { application.isRunning ? [application] : [] },
            applicationLauncher: { _, _ in events.append("launch") },
            sleep: { _ in
                polls += 1
                if polls == 20 { application.isRunning = false }
            }
        )

        try await controller.restart(beforeLaunch: {
            XCTAssertTrue(application.isTerminated)
            events.append("credentials")
        })

        XCTAssertEqual(polls, 20)
        XCTAssertEqual(application.forceTerminateCallCount, 0)
        XCTAssertEqual(events, ["credentials", "launch"])
    }

    func testFailedAccountSwitchRestoresOriginalWindowWhenQuitFinishesAfterTimeout() async throws {
        let application = StubRunningCodexApplication()
        let restored = expectation(description: "Original window reopened")
        var polls = 0
        var changedCredentials = false
        let controller = CodexProcessController(
            applicationURL: URL(fileURLWithPath: "/Applications"),
            runningApplicationsProvider: { application.isRunning ? [application] : [] },
            applicationLauncher: { _, configuration in
                XCTAssertFalse(changedCredentials)
                XCTAssertFalse(configuration.activates)
                restored.fulfill()
            },
            sleep: { _ in
                polls += 1
                if polls == 65 { application.isRunning = false }
            }
        )

        do {
            try await controller.restart(beforeLaunch: { changedCredentials = true })
            XCTFail("Expected the account switch to time out")
        } catch {
            guard case DashboardError.codexQuitTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [restored], timeout: 2)

        XCTAssertFalse(changedCredentials)
        XCTAssertEqual(application.forceTerminateCallCount, 0)
    }

    func testRestartForceTerminatesCodexWhenGracefulQuitDoesNotExit() async throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProcessControllerTests-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        let application = StubRunningCodexApplication()
        var launchedArguments: [String]?
        let controller = CodexProcessController(
            applicationURL: applicationURL,
            runningApplicationsProvider: { application.isRunning ? [application] : [] },
            applicationLauncher: { _, configuration in
                launchedArguments = configuration.arguments
            },
            sleep: { _ in }
        )

        try await controller.restart()

        XCTAssertEqual(application.terminateCallCount, 1)
        XCTAssertEqual(application.forceTerminateCallCount, 1)
        XCTAssertEqual(launchedArguments, CodexConfiguration.launchArguments)
    }

    func testRestartDoesNotForceTerminateAfterGracefulExit() async throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProcessControllerTests-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        let application = StubRunningCodexApplication()
        application.exitsGracefully = true
        var didLaunch = false
        var activates: Bool?
        let controller = CodexProcessController(
            applicationURL: applicationURL,
            runningApplicationsProvider: { application.isRunning ? [application] : [] },
            applicationLauncher: { _, configuration in
                didLaunch = true
                activates = configuration.activates
            },
            sleep: { _ in }
        )

        try await controller.restart(activate: false)

        XCTAssertEqual(activates, false)
        XCTAssertEqual(application.terminateCallCount, 1)
        XCTAssertEqual(application.forceTerminateCallCount, 0)
        XCTAssertTrue(didLaunch)
    }
}
