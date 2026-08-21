import AppKit
import Foundation

@MainActor
final class CodexProcessController {
    var isRunning: Bool {
        !runningApplications.isEmpty
    }

    var launchDate: Date? {
        runningApplications.compactMap(\.launchDate).max()
    }

    func restart() async throws {
        let applicationURL = CodexConfiguration.codexApplicationURL
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DashboardError.missingCodexApplication
        }

        runningApplications.forEach { $0.terminate() }
        let quitDeadline = ContinuousClock.now + .seconds(12)
        while isRunning {
            guard ContinuousClock.now < quitDeadline else {
                throw DashboardError.codexQuitTimedOut
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let launchConfiguration = NSWorkspace.OpenConfiguration()
        launchConfiguration.arguments = CodexConfiguration.launchArguments
        launchConfiguration.activates = true
        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: launchConfiguration
        )
    }

    private var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        )
    }
}
