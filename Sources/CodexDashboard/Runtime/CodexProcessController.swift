import AppKit
import Foundation
import OSLog

@MainActor
protocol RunningCodexApplication: AnyObject {
    var launchDate: Date? { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
    func forceTerminate() -> Bool
}

extension NSRunningApplication: RunningCodexApplication {}

@MainActor
final class CodexProcessController {
    private static let pollInterval = Duration.milliseconds(250)
    private static let gracefulQuitPollLimit = 12
    private static let accountSwitchQuitPollLimit = 60
    private static let forcedQuitPollLimit = 36
    private static let logger = Logger(subsystem: "local.lawrenceawe.codex-dashboard", category: "Codex restart")

    private let applicationURL: URL
    private let runningApplicationsProvider: () -> [any RunningCodexApplication]
    private let applicationLauncher: (URL, NSWorkspace.OpenConfiguration) async throws -> Void
    private let makeLaunchConfiguration: () -> NSWorkspace.OpenConfiguration
    private let sleep: (Duration) async throws -> Void
    private var quitRecoveryTask: Task<Void, Never>?

    init(
        applicationURL: URL = CodexConfiguration.codexApplicationURL,
        runningApplicationsProvider: @escaping () -> [any RunningCodexApplication] = {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: CodexConfiguration.bundleIdentifier
            ).filter { CodexConfiguration.isMainApplication($0) }
        },
        applicationLauncher: @escaping (URL, NSWorkspace.OpenConfiguration) async throws -> Void = { url, configuration in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        },
        makeLaunchConfiguration: (() -> NSWorkspace.OpenConfiguration)? = nil,
        sleep: @escaping (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.applicationURL = applicationURL
        self.runningApplicationsProvider = runningApplicationsProvider
        self.applicationLauncher = applicationLauncher
        self.sleep = sleep
        self.makeLaunchConfiguration = makeLaunchConfiguration ?? {
            CodexConfiguration.selectFreshDevToolsPortForLaunch()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = CodexConfiguration.launchArguments
            configuration.environment = ChatHandoffService.environment(windowID: "main")
            return configuration
        }
    }

    var isRunning: Bool {
        !runningApplications.isEmpty
    }

    var launchDate: Date? {
        runningApplications.compactMap(\.launchDate).max()
    }

    func restart(activate: Bool = true, beforeLaunch: (() async throws -> Void)? = nil) async throws {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DashboardError.missingCodexApplication
        }

        quitRecoveryTask?.cancel()
        quitRecoveryTask = nil
        let applications = runningApplications
        Self.logger.notice("Requesting graceful Codex shutdown")
        applications.forEach { _ = $0.terminate() }
        // Wait on the applications being quit. Process-argument discovery can
        // change while Launch Services is still completing their termination.
        var gracefulQuitPollsRemaining = beforeLaunch == nil
            ? Self.gracefulQuitPollLimit : Self.accountSwitchQuitPollLimit
        while applications.contains(where: { !$0.isTerminated }), gracefulQuitPollsRemaining > 0 {
            try await sleep(Self.pollInterval)
            gracefulQuitPollsRemaining -= 1
        }
        if applications.contains(where: { !$0.isTerminated }) {
            guard beforeLaunch == nil else {
                restoreWindowAfterDelayedQuit(applications)
                throw DashboardError.codexQuitTimedOut
            }
            applications.forEach { _ = $0.forceTerminate() }
        }
        var forcedQuitPollsRemaining = Self.forcedQuitPollLimit
        while applications.contains(where: { !$0.isTerminated }), forcedQuitPollsRemaining > 0 {
            try await sleep(Self.pollInterval)
            forcedQuitPollsRemaining -= 1
        }
        guard applications.allSatisfy(\.isTerminated), !isRunning else {
            throw DashboardError.codexQuitTimedOut
        }

        Self.logger.notice("Codex exited; preparing replacement window")
        try await beforeLaunch?()
        let launchConfiguration = makeLaunchConfiguration()
        launchConfiguration.activates = activate
        try await applicationLauncher(applicationURL, launchConfiguration)
        Self.logger.notice("Replacement Codex window launched")
    }

    private func restoreWindowAfterDelayedQuit(_ applications: [any RunningCodexApplication]) {
        // The account transaction has not run. If a slow quit finishes after the
        // timeout, reopen the original account instead of leaving its window shut.
        quitRecoveryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<240 {
                guard !Task.isCancelled else { return }
                if applications.allSatisfy(\.isTerminated) {
                    guard !isRunning else { return }
                    let configuration = makeLaunchConfiguration()
                    configuration.activates = false
                    do {
                        try await applicationLauncher(applicationURL, configuration)
                        Self.logger.notice("Restored original Codex window after delayed shutdown")
                    } catch {
                        Self.logger.error("Could not restore Codex window after delayed shutdown")
                    }
                    return
                }
                do { try await sleep(Self.pollInterval) }
                catch { return }
            }
        }
    }

    private var runningApplications: [any RunningCodexApplication] {
        runningApplicationsProvider()
    }
}
