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
    private var accountUsageCancellable: AnyCancellable?
    private var savedAccountUsageCancellable: AnyCancellable?
    private var accountUsageProgressCancellable: AnyCancellable?
    private var accountUsageErrorCancellable: AnyCancellable?
    private weak var accountsMenuItem: NSMenuItem?

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
        accountUsageCancellable = coordinator.$activeAccountUsageStatus
            .dropFirst()
            .sink { [weak self] _ in self?.refreshAccountsMenu() }
        savedAccountUsageCancellable = coordinator.$usageByAccountID
            .dropFirst()
            .sink { [weak self] _ in self?.refreshAccountsMenu() }
        accountUsageProgressCancellable = coordinator.$refreshingUsageAccountIDs
            .dropFirst()
            .sink { [weak self] _ in self?.refreshAccountsMenu() }
        accountUsageErrorCancellable = coordinator.$usageErrorsByAccountID
            .dropFirst()
            .sink { [weak self] _ in self?.refreshAccountsMenu() }
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

        let accountsItem = NSMenuItem(title: accountMenuTitle, action: nil, keyEquivalent: "")
        accountsItem.submenu = makeAccountsMenu()
        accountsMenuItem = accountsItem
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
        populateAccountsMenu(menu)
        return menu
    }

    private func populateAccountsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, account) in coordinator.savedAccounts.enumerated() {
            let isActive = account.id == coordinator.activeAccountID
            let item = actionItem(account.name, action: #selector(switchAccount(_:)))
            item.representedObject = account.id.uuidString
            item.state = isActive ? .on : .off
            item.isEnabled = !isActive && !coordinator.isPerformingAction
            menu.addItem(item)
            let usageTitles: [String]
            if isActive {
                usageTitles = AccountUsageMenuFormatter.titles(
                    for: coordinator.activeAccountUsageStatus
                )
            } else if let snapshot = coordinator.usageByAccountID[account.id] {
                usageTitles = AccountUsageMenuFormatter.titles(
                    for: .stale(snapshot),
                    staleLabel: "Cached usage"
                )
            } else {
                usageTitles = ["Usage details unavailable"]
            }
            addUsageItems(usageTitles, to: menu)
            if !isActive {
                let isRefreshing = coordinator.refreshingUsageAccountIDs.contains(account.id)
                let update = persistentActionItem(
                    isRefreshing ? "Updating Usage…" : "Update Usage",
                    indentationLevel: 1,
                    isEnabled: coordinator.refreshingUsageAccountIDs.isEmpty
                        && !coordinator.isPerformingAction
                ) { [weak self] in
                    Task { await self?.coordinator.refreshSavedAccountUsage(account.id) }
                }
                menu.addItem(update)
                if let error = coordinator.usageErrorsByAccountID[account.id] {
                    let failure = NSMenuItem(
                        title: "Update failed: \(error)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    failure.indentationLevel = 1
                    failure.isEnabled = false
                    menu.addItem(failure)
                }
            }
            if index < coordinator.savedAccounts.count - 1 { menu.addItem(.separator()) }
        }
        if coordinator.activeAccountID == nil {
            if !coordinator.savedAccounts.isEmpty { menu.addItem(.separator()) }
            let current = NSMenuItem(title: "Current account", action: nil, keyEquivalent: "")
            current.state = .on
            current.isEnabled = false
            menu.addItem(current)
            addUsageItems(
                AccountUsageMenuFormatter.titles(for: coordinator.activeAccountUsageStatus),
                to: menu
            )
        }
        menu.addItem(.separator())
        if coordinator.savedAccounts.count > 1 {
            let updateAll = persistentActionItem(
                "Update Signed-Out Usage",
                isEnabled: !coordinator.isPerformingAction
                    && coordinator.refreshingUsageAccountIDs.isEmpty
            ) { [weak self] in
                Task { await self?.coordinator.refreshInactiveAccountUsage() }
            }
            menu.addItem(updateAll)
            menu.addItem(.separator())
        }
        let save = actionItem("Save Current Account", action: #selector(saveCurrentAccount))
        save.isEnabled = !coordinator.isPerformingAction
        menu.addItem(save)
        let add = actionItem("Sign In to Another Account…", action: #selector(addAccount))
        add.isEnabled = !coordinator.isPerformingAction
        menu.addItem(add)
        if !coordinator.savedAccounts.isEmpty {
            let forget = NSMenuItem(title: "Forget Saved Account", action: nil, keyEquivalent: "")
            let forgetMenu = NSMenu(title: "Forget Saved Account")
            for account in coordinator.savedAccounts {
                let item = actionItem(account.name, action: #selector(forgetAccount(_:)))
                item.representedObject = account.id.uuidString
                forgetMenu.addItem(item)
            }
            forget.submenu = forgetMenu
            menu.addItem(forget)
        }
    }

    private func persistentActionItem(
        _ title: String,
        indentationLevel: Int = 0,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = PersistentMenuActionView(
            title: title,
            indentationLevel: indentationLevel,
            isEnabled: isEnabled,
            action: action
        )
        return item
    }

    private func addUsageItems(_ titles: [String], to menu: NSMenu) {
        for title in titles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.indentationLevel = 1
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func refreshAccountsMenu() {
        guard let accountsMenuItem, let menu = accountsMenuItem.submenu else { return }
        accountsMenuItem.title = accountMenuTitle
        populateAccountsMenu(menu)
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
        coordinator.saveCurrentAccount()
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
            let accountID = UUID(uuidString: identifier)
        else { return }
        Task { await coordinator.switchAccount(to: accountID) }
    }

    @objc private func forgetAccount(_ sender: NSMenuItem) {
        guard
            let identifier = sender.representedObject as? String,
            let accountID = UUID(uuidString: identifier),
            let account = coordinator.savedAccounts.first(where: { $0.id == accountID })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(account.name)?"
        alert.informativeText = "Its saved credentials will be removed from Keychain. This does not delete the OpenAI account."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.deleteAccount(accountID)
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
