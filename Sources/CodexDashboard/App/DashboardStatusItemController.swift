import AppKit
import Combine

@MainActor
final class DashboardStatusItemController: NSObject, NSMenuDelegate {
    private static let autosaveName = "CodexDashboardStatusItem"
    private static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let defaultPreferredPosition = 450

    private let coordinator: AppCoordinator
    private let launchAtLogin: LaunchAtLoginController
    private let statusItem: NSStatusItem
    private var connectionStateCancellable: AnyCancellable?

    init(
        coordinator: AppCoordinator,
        launchAtLogin: LaunchAtLoginController
    ) {
        Self.registerDefaultPosition()
        self.coordinator = coordinator
        self.launchAtLogin = launchAtLogin
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = Self.autosaveName
        statusItem.isVisible = true
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateIcon(for: coordinator.connectionState)

        connectionStateCancellable = coordinator.$connectionState.sink { [weak self] state in
            self?.updateIcon(for: state)
        }
    }

    static func registerDefaultPosition(in userDefaults: UserDefaults = .standard) {
        guard userDefaults.object(forKey: preferredPositionKey) == nil else { return }
        userDefaults.set(defaultPreferredPosition, forKey: preferredPositionKey)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        coordinator.refreshAccountState()
        Task { await coordinator.refreshAccountUsage() }
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusPresentation.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(actionItem("Open Diagnostics…", action: #selector(openDiagnostics)))
        menu.addItem(.separator())

        let actions = coordinator.dashboardActions
        let openDashboard = actionItem(
            DashboardActionPresentation.openTitle,
            action: #selector(openThreadDashboard)
        )
        openDashboard.isEnabled = actions.canOpen
        menu.addItem(openDashboard)

        let restart = actionItem(
            DashboardActionPresentation.restartTitle,
            action: #selector(restartAndEnable)
        )
        restart.isEnabled = actions.canRestart
        menu.addItem(restart)

        let disable = actionItem(
            DashboardActionPresentation.disableTitle,
            action: #selector(disableThreadDashboard)
        )
        disable.isEnabled = actions.canDisable
        menu.addItem(disable)
        menu.addItem(.separator())

        let compatibilityTitle = coordinator.isCheckingCompatibility
            ? "Checking Compatibility…"
            : "Check Compatibility"
        let compatibility = actionItem(compatibilityTitle, action: #selector(checkCompatibility))
        compatibility.isEnabled = !coordinator.isCheckingCompatibility
        menu.addItem(compatibility)
        menu.addItem(.separator())

        let launchItem = actionItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
        launchItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)
        let foregroundItem = actionItem(
            "Bring Codex to Front on Task Completion",
            action: #selector(toggleForegroundOnTaskCompletion)
        )
        foregroundItem.state = coordinator.foregroundOnTaskCompletion ? .on : .off
        menu.addItem(foregroundItem)
        menu.addItem(actionItem("Copy Diagnostics", action: #selector(copyDiagnostics)))
        menu.addItem(actionItem("Export Prompt Library…", action: #selector(exportPromptLibrary)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Codex Dashboard", action: #selector(quit)))
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateIcon(for state: DashboardConnectionState) {
        let symbolName = state.dashboardIsMounted ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Codex Dashboard")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Codex Dashboard"
    }

    @objc private func openDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openThreadDashboard() {
        Task { await coordinator.openThreadDashboard() }
    }

    @objc private func restartAndEnable() {
        Task { await coordinator.restartCodexAndEnableThreadDashboard() }
    }

    @objc private func disableThreadDashboard() {
        Task { await coordinator.disableThreadDashboard() }
    }

    @objc private func checkCompatibility() {
        openDiagnostics()
        Task { await coordinator.checkCompatibility() }
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
    }

    @objc private func toggleForegroundOnTaskCompletion() {
        coordinator.foregroundOnTaskCompletion.toggle()
    }

    @objc private func copyDiagnostics() {
        coordinator.copyDiagnostics()
    }

    @objc private func exportPromptLibrary() {
        coordinator.exportPromptLibrary()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
