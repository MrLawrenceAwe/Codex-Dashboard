import AppKit
import SwiftUI

@MainActor
final class CodexDashboardAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
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
struct CodexDashboardApp: App {
    @NSApplicationDelegateAdaptor(CodexDashboardAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DiagnosticsWindowView(coordinator: appDelegate.coordinator)
        }
    }
}
