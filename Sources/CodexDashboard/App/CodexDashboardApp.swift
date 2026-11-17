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
        ) where application.processIdentifier != currentProcessID
            && !(CodexConfiguration.processArguments(for: application.processIdentifier)?.contains("--shared-chat-server ") ?? false) {
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
        accountWindowDashboards.start()
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
        if arguments.first == "--shared-chat-server" {
            guard arguments.count == 2, let path = arguments.last else { exit(2) }
            do {
                let configuration = try JSONDecoder().decode(ChatHandoffServer.Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let server = ChatHandoffServer(configuration: configuration)
                let endpoints = try await server.start()
                let data = try JSONEncoder().encode(endpoints)
                for name in ["connections.json", "ready.json"] {
                    let file = configuration.root.appendingPathComponent(name)
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
                server.handleTermination()
                while true { try await Task.sleep(for: .seconds(60)) }
            } catch {
                let message = (error as? ChatHandoffError)?.errorDescription ?? "See shared-chat diagnostics for startup details."
                FileHandle.standardError.write(Data(("Shared chat startup failed. " + message + "\n").utf8))
                exit(1)
            }
        }
        if arguments.first == "--managed-shared-windows" || arguments.first == "--recover-managed-shared-windows" {
            let accounts = AccountCoordinator(manager: CodexAccountManager(), usageProvider: AppServerUsageProvider())
            await accounts.refreshState()
            do {
                if arguments.first == "--managed-shared-windows" {
                    try await ManagedChatController.shared.openAll(accounts: accounts)
                } else {
                    try await ManagedChatController.shared.recover(accounts: accounts)
                }
                print("Managed shared windows are ready.")
                return
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
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
        do {
            try LegacySharedChatRecovery().recover()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Dashboard could not retire the old Shared Chats connection."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit Dashboard")
            alert.runModal()
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
