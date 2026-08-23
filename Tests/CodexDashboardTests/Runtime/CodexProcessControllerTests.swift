import AppKit
import XCTest

@testable import CodexDashboard

@MainActor
private final class StubRunningCodexApplication: RunningCodexApplication {
    let launchDate: Date? = .now
    var isRunning = true
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
        let controller = CodexProcessController(
            applicationURL: applicationURL,
            runningApplicationsProvider: { application.isRunning ? [application] : [] },
            applicationLauncher: { _, _ in didLaunch = true },
            sleep: { _ in }
        )

        try await controller.restart()

        XCTAssertEqual(application.terminateCallCount, 1)
        XCTAssertEqual(application.forceTerminateCallCount, 0)
        XCTAssertTrue(didLaunch)
    }
}
