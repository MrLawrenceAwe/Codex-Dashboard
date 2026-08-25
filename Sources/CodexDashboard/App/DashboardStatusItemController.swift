import AppKit
import Combine

@MainActor
final class DashboardStatusItemController: NSObject, NSMenuDelegate {
    private static let autosaveName = "CodexDashboardStatusItem"
    private static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let defaultPreferredPosition = 450

    private let coordinator: DashboardCoordinator
    private let launchAtLogin: LaunchAtLoginController
    private let statusItem: NSStatusItem
    private var connectionStateCancellable: AnyCancellable?

    init(
        coordinator: DashboardCoordinator,
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
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusPresentation.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(actionItem("Open Diagnostics…", action: #selector(openDiagnostics)))
        menu.addItem(.separator())

        let openDashboard = actionItem("Open Thread Dashboard", action: #selector(openThreadDashboard))
        openDashboard.isEnabled = coordinator.connectionState.dashboardIsMounted
        menu.addItem(openDashboard)

        let restart = actionItem("Restart & Enable", action: #selector(restartAndEnable))
        restart.isEnabled = !coordinator.isPerformingAction && !coordinator.isCheckingCompatibility
        menu.addItem(restart)

        let disable = actionItem("Disable Thread Dashboard", action: #selector(disableThreadDashboard))
        disable.isEnabled = coordinator.connectionState.rendererIsAvailable && !coordinator.isPerformingAction
        menu.addItem(disable)
        menu.addItem(.separator())

        let accountsItem = NSMenuItem(title: accountMenuTitle, action: nil, keyEquivalent: "")
        accountsItem.submenu = makeAccountsMenu()
        menu.addItem(accountsItem)
        if let message = coordinator.accountStatusMessage {
            let accountStatus = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            accountStatus.isEnabled = false
            menu.addItem(accountStatus)
        }
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

    private var accountMenuTitle: String {
        coordinator.activeAccountName.map { "Account: \($0)" } ?? "Accounts"
    }

    private func makeAccountsMenu() -> NSMenu {
        let menu = NSMenu(title: "Accounts")
        for profile in coordinator.accountProfiles {
            let item = actionItem(profile.name, action: #selector(switchAccount(_:)))
            item.representedObject = profile.id.uuidString
            item.state = profile.id == coordinator.activeAccountProfileID ? .on : .off
            item.isEnabled = profile.id != coordinator.activeAccountProfileID
                && !coordinator.isPerformingAction
            menu.addItem(item)
        }
        if !coordinator.accountProfiles.isEmpty { menu.addItem(.separator()) }
        let save = actionItem("Save Current Account…", action: #selector(saveCurrentAccount))
        save.isEnabled = !coordinator.isPerformingAction
        menu.addItem(save)
        let add = actionItem("Sign In to Another Account…", action: #selector(addAccount))
        add.isEnabled = !coordinator.isPerformingAction
        menu.addItem(add)
        if !coordinator.accountProfiles.isEmpty {
            let forget = NSMenuItem(title: "Forget Saved Account", action: nil, keyEquivalent: "")
            let forgetMenu = NSMenu(title: "Forget Saved Account")
            for profile in coordinator.accountProfiles {
                let item = actionItem(profile.name, action: #selector(forgetAccount(_:)))
                item.representedObject = profile.id.uuidString
                forgetMenu.addItem(item)
            }
            forget.submenu = forgetMenu
            menu.addItem(forget)
        }
        return menu
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

    @objc private func saveCurrentAccount() {
        let alert = NSAlert()
        alert.messageText = coordinator.activeAccountName == nil
            ? "Save Current Codex Account"
            : "Rename and Update Saved Account"
        alert.informativeText = "Credentials are stored in macOS Keychain and are never written to the dashboard's settings file."
        let field = NSTextField(string: coordinator.activeAccountName ?? "")
        field.placeholderString = "Account Name"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.saveCurrentAccount(named: field.stringValue)
    }

    @objc private func addAccount() {
        let alert = NSAlert()
        alert.messageText = "Sign In to Another Codex Account?"
        alert.informativeText = "Codex will restart signed out. After signing in, choose Save Current Account from this menu. Existing saved accounts remain in Keychain."
        alert.addButton(withTitle: "Restart and Sign In")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await coordinator.beginAddingAccount() }
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard
            let identifier = sender.representedObject as? String,
            let profileID = UUID(uuidString: identifier)
        else { return }
        Task { await coordinator.switchAccount(to: profileID) }
    }

    @objc private func forgetAccount(_ sender: NSMenuItem) {
        guard
            let identifier = sender.representedObject as? String,
            let profileID = UUID(uuidString: identifier),
            let profile = coordinator.accountProfiles.first(where: { $0.id == profileID })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(profile.name)?"
        alert.informativeText = "Its saved credentials will be removed from Keychain. This does not delete the OpenAI account."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.deleteAccount(profileID)
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
