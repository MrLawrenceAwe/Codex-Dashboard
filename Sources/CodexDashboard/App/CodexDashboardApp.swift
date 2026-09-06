import AppKit
import SwiftUI

@MainActor
final class CodexDashboardAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator(
        compatibilityIssueNotifier: CompatibilityIssueNotifier(),
        accountResetNotifier: AccountResetNotifier(),
        phoneResetNotifier: NtfyResetNotifier()
    )
    let launchAtLogin = LaunchAtLoginController()
    private var statusItemController: DashboardStatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) where application.processIdentifier != currentProcessID {
            application.forceTerminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = DashboardStatusItemController(
            coordinator: coordinator,
            launchAtLogin: launchAtLogin
        )
        coordinator.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopMonitoring()
    }
}

@main
enum CodexDashboardMain {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--export-preview-injection" {
            guard arguments.count == 2, let path = arguments.last else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try InjectionBundle.load().mountExpression.write(
                toFile: path, atomically: true, encoding: .utf8
            )
            return
        }
        CodexDashboardApp.main()
    }
}

struct CodexDashboardApp: App {
    @NSApplicationDelegateAdaptor(CodexDashboardAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DiagnosticsWindowView(coordinator: appDelegate.coordinator)
        }
    }
}
