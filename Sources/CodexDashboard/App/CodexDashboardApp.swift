import AppKit
import ServiceManagement
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
    @StateObject private var coordinator = DashboardCoordinator()
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some Scene {
        Settings {
            DiagnosticsWindowView(coordinator: coordinator)
        }

        MenuBarExtra {
            DashboardMenu(coordinator: coordinator, launchAtLogin: launchAtLogin)
        } label: {
            Image(systemName: coordinator.connectionState.dashboardIsMounted
                  ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2")
                .accessibilityLabel("Codex Dashboard")
                .task {
                    coordinator.startMonitoring()
                }
        }
    }
}

private struct DashboardMenu: View {
    @ObservedObject var coordinator: DashboardCoordinator
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(coordinator.statusPresentation.title)
        Button("Open Diagnostics…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Open Thread Dashboard") { Task { await coordinator.openThreadDashboard() } }
            .disabled(!coordinator.connectionState.dashboardIsMounted)
        Button("Restart & Enable") { Task { await coordinator.restartCodexAndEnableThreadDashboard() } }
            .disabled(coordinator.isPerformingAction)
        Button("Disable Thread Dashboard") { Task { await coordinator.disableThreadDashboard() } }
            .disabled(!coordinator.connectionState.rendererIsAvailable || coordinator.isPerformingAction)
        Divider()
        Button(coordinator.isCheckingCompatibility ? "Checking Compatibility…" : "Check Compatibility") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
            Task { await coordinator.checkCompatibility() }
        }
        .disabled(coordinator.isCheckingCompatibility)
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        ))
        Button("Copy Diagnostics") { coordinator.copyDiagnostics() }
        Divider()
        Button("Quit Codex Dashboard") { NSApp.terminate(nil) }
    }
}
