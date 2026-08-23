import AppKit

@MainActor
protocol CodexForegrounding {
    func foregroundCodex()
}

@MainActor
final class CodexApplicationForegroundController: CodexForegrounding {
    func foregroundCodex() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CodexConfiguration.bundleIdentifier else {
            return
        }
        let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        ).max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        application?.activate(options: [.activateAllWindows])
    }
}
