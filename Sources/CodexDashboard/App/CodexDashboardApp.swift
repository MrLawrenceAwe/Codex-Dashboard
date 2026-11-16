import AppKit
import SwiftUI

@MainActor
final class CodexDashboardAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator(
        compatibilityIssueNotifier: CompatibilityIssueNotifier(),
        desktopUsageNotifier: DesktopUsageNotifier(),
        phoneUsageNotifier: NtfyUsageNotifier()
    )
    let launchAtLogin = LaunchAtLoginController()
    let accountWindowDashboards = AccountWindowDashboards()
    private var statusItemController: DashboardStatusItemController?
    private var diagnosticsWindowController: DiagnosticsWindowController?

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
        let diagnosticsWindowController = DiagnosticsWindowController(coordinator: coordinator)
        self.diagnosticsWindowController = diagnosticsWindowController
        statusItemController = DashboardStatusItemController(
            coordinator: coordinator,
            accountWindowDashboards: accountWindowDashboards,
            launchAtLogin: launchAtLogin,
            showDiagnostics: { diagnosticsWindowController.showDiagnostics() }
        )
        coordinator.startMonitoring()
        accountWindowDashboards.start(main: coordinator)
    }

    func applicationWillTerminate(_ notification: Notification) {
        accountWindowDashboards.stop()
        coordinator.stopMonitoring()
    }
}

@main
enum CodexDashboardMain {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--shared-chat-server", arguments.count == 2, let path = arguments.last {
            let configuration = try JSONDecoder().decode(ChatHandoffServer.Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let server = ChatHandoffServer(configuration: configuration)
            let endpoints = try await server.start()
            let ready = server.readyFile
            try JSONEncoder().encode(endpoints).write(to: ready, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ready.path)
            server.handleTermination()
            while true { try await Task.sleep(for: .seconds(60)) }
        }
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
            EmptyView()
        }
    }
}
