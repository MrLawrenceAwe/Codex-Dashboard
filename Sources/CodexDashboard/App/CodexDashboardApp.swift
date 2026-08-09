import AppKit
import SwiftUI

final class CodexDashboardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) where application.processIdentifier != currentProcessID {
            application.forceTerminate()
        }
    }
}

@main
struct CodexDashboardApp: App {
    @NSApplicationDelegateAdaptor(CodexDashboardAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardControllerView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
