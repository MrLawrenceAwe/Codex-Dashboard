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
    @StateObject private var viewModel = DashboardViewModel()
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some Scene {
        WindowGroup(id: "controller") {
            DashboardControllerView(viewModel: viewModel, launchAtLogin: launchAtLogin)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            DashboardMenu(viewModel: viewModel, launchAtLogin: launchAtLogin)
        } label: {
            Image(systemName: viewModel.connectionState.dashboardIsMounted
                  ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2")
                .accessibilityLabel("Codex Dashboard")
        }
    }
}

private struct DashboardMenu: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(viewModel.statusPresentation.title)
        Button("Open Controller") {
            openWindow(id: "controller")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Thread Dashboard") { Task { await viewModel.openThreadDashboard() } }
            .disabled(!viewModel.connectionState.dashboardIsMounted)
        Button("Sync Now") { Task { await viewModel.synchronizeDashboard() } }
        Button("Restart & Enable") { Task { await viewModel.restartCodexAndEnableThreadDashboard() } }
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        ))
        Button("Copy Diagnostics") { viewModel.copyDiagnostics() }
        Divider()
        Button("Quit Codex Dashboard") { NSApp.terminate(nil) }
    }
}
