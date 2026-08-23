import AppKit
import Foundation

@MainActor
protocol RunningCodexApplication: AnyObject {
    var launchDate: Date? { get }
    func terminate() -> Bool
    func forceTerminate() -> Bool
}

extension NSRunningApplication: RunningCodexApplication {}

@MainActor
final class CodexProcessController {
    private static let pollInterval = Duration.milliseconds(250)
    private static let gracefulQuitPollLimit = 12
    private static let forcedQuitPollLimit = 36

    private let applicationURL: URL
    private let runningApplicationsProvider: () -> [any RunningCodexApplication]
    private let applicationLauncher: (URL, NSWorkspace.OpenConfiguration) async throws -> Void
    private let sleep: (Duration) async throws -> Void

    init(
        applicationURL: URL = CodexConfiguration.codexApplicationURL,
        runningApplicationsProvider: @escaping () -> [any RunningCodexApplication] = {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: CodexConfiguration.bundleIdentifier
            )
        },
        applicationLauncher: @escaping (URL, NSWorkspace.OpenConfiguration) async throws -> Void = { url, configuration in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        },
        sleep: @escaping (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.applicationURL = applicationURL
        self.runningApplicationsProvider = runningApplicationsProvider
        self.applicationLauncher = applicationLauncher
        self.sleep = sleep
    }

    var isRunning: Bool {
        !runningApplications.isEmpty
    }

    var launchDate: Date? {
        runningApplications.compactMap(\.launchDate).max()
    }

    func restart() async throws {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DashboardError.missingCodexApplication
        }

        runningApplications.forEach { _ = $0.terminate() }
        var gracefulQuitPollsRemaining = Self.gracefulQuitPollLimit
        while isRunning, gracefulQuitPollsRemaining > 0 {
            try await sleep(Self.pollInterval)
            gracefulQuitPollsRemaining -= 1
        }
        if isRunning {
            runningApplications.forEach { _ = $0.forceTerminate() }
        }
        var forcedQuitPollsRemaining = Self.forcedQuitPollLimit
        while isRunning, forcedQuitPollsRemaining > 0 {
            try await sleep(Self.pollInterval)
            forcedQuitPollsRemaining -= 1
        }
        guard !isRunning else {
            throw DashboardError.codexQuitTimedOut
        }

        let launchConfiguration = NSWorkspace.OpenConfiguration()
        launchConfiguration.arguments = CodexConfiguration.launchArguments
        launchConfiguration.activates = true
        try await applicationLauncher(applicationURL, launchConfiguration)
    }

    private var runningApplications: [any RunningCodexApplication] {
        runningApplicationsProvider()
    }
}
