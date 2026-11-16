import AppKit

@MainActor
protocol CodexForegrounding {
    var isCodexFrontmost: Bool { get }
    func foregroundCodex()
}

@MainActor
final class CodexApplicationForegroundController: CodexForegrounding {
    var isCodexFrontmost: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == CodexConfiguration.bundleIdentifier else { return false }
        return CodexConfiguration.isMainApplication(app)
    }

    func foregroundCodex() {
        guard !isCodexFrontmost else {
            return
        }
        let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        ).filter { CodexConfiguration.isMainApplication($0) }.max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        application?.activate(options: [.activateAllWindows])
    }
}
