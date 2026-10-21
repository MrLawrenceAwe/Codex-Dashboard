import AppKit

@MainActor
protocol CodexForegrounding {
    func foregroundCodex()
}

@MainActor
final class CodexApplicationForegroundController: CodexForegrounding {
    private var isCodexFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexConfiguration.bundleIdentifier
    }

    func foregroundCodex() {
        guard !isCodexFrontmost else {
            return
        }
        let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        ).max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        application?.activate(options: [.activateAllWindows])
    }
}
