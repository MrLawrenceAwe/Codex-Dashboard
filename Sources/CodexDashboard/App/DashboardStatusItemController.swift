import AppKit
import Combine

@MainActor
final class DashboardStatusItemController: NSObject, NSMenuDelegate {
    private static let autosaveName = "CodexDashboardStatusItem"
    private static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let defaultPreferredPosition = 450

    private let coordinator: AppCoordinator
    private let accountWindowDashboards: AccountWindowDashboards?
    private let launchAtLogin: LaunchAtLoginController
    private let showDiagnostics: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private var statusPresentationCancellable: AnyCancellable?

    init(
        coordinator: AppCoordinator,
        accountWindowDashboards: AccountWindowDashboards? = nil,
        launchAtLogin: LaunchAtLoginController,
        showDiagnostics: @escaping @MainActor () -> Void
    ) {
        Self.registerDefaultPosition()
        self.coordinator = coordinator
        self.accountWindowDashboards = accountWindowDashboards
        self.launchAtLogin = launchAtLogin
        self.showDiagnostics = showDiagnostics
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = Self.autosaveName
        statusItem.isVisible = true
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateIcon(for: coordinator.connectionState, report: coordinator.compatibilityReport)

        statusPresentationCancellable = Publishers.CombineLatest(
            coordinator.$connectionState,
            coordinator.$compatibilityReport
        ).sink { [weak self] state, report in
            self?.updateIcon(for: state, report: report)
        }
    }

    static func registerDefaultPosition(in userDefaults: UserDefaults = .standard) {
        guard userDefaults.object(forKey: preferredPositionKey) == nil else { return }
        userDefaults.set(defaultPreferredPosition, forKey: preferredPositionKey)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Task {
            await coordinator.refreshAccountState()
            await coordinator.refreshAccountUsage()
        }
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusPresentation.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let report = coordinator.compatibilityReport,
           report.blockingCount > 0 || report.nonBlockingAttentionCount > 0 {
            let compatibilityStatus = NSMenuItem(
                title: "Compatibility: \(report.attentionSummary ?? report.summary)",
                action: nil,
                keyEquivalent: ""
            )
            compatibilityStatus.isEnabled = false
            menu.addItem(compatibilityStatus)
        }
        let diagnosticsTitle = Self.requiresCompatibilityAttention(coordinator.compatibilityReport)
            ? "Review Compatibility…"
            : "Open Diagnostics…"
        menu.addItem(actionItem(diagnosticsTitle, action: #selector(openDiagnostics)))
        menu.addItem(.separator())

        let actions = coordinator.dashboardActions
        let openDashboard = actionItem(
            DashboardActionPresentation.openTitle,
            action: #selector(openChatOverview)
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
            action: #selector(disableIntegration)
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

        let sharedRunning = ChatHandoffService.isRunning
        let sharedCurrent = sharedRunning && ChatHandoffService.supportsAccountSwitch
        let sharedTitle: String
        if sharedCurrent {
            sharedTitle = "Shared Chats Enabled"
        } else if ChatHandoffService.isEnabled && (!sharedRunning || !ChatHandoffService.hasReadyEndpoint) {
            sharedTitle = "Reconnect Shared Chats (Restarts Codex Windows)"
        } else if sharedRunning {
            sharedTitle = "Update Shared Chats (Restarts Codex Windows)"
        } else {
            sharedTitle = "Enable Shared Chats (Restarts Codex Windows)"
        }
        let shared = actionItem(sharedTitle, action: #selector(enableSharedChats))
        shared.isEnabled = !sharedCurrent && !coordinator.isPerformingAction
        menu.addItem(shared)
        if ChatHandoffService.isEnabled {
            let disableShared = actionItem("Disable Shared Chats (Restarts Codex Windows)", action: #selector(disableSharedChats))
            disableShared.isEnabled = !coordinator.isPerformingAction
            menu.addItem(disableShared)
        }
        let accountWindows = NSMenuItem(title: "Open Account Window", action: nil, keyEquivalent: "")
        let accountWindowMenu = NSMenu()
        for account in coordinator.accounts.savedAccounts {
            let item = actionItem(account.name, action: #selector(openAccountWindow(_:)))
            item.representedObject = account.id
            item.isEnabled = !coordinator.isPerformingAction
            accountWindowMenu.addItem(item)
        }
        accountWindows.submenu = accountWindowMenu
        accountWindows.isEnabled = !coordinator.accounts.savedAccounts.isEmpty
        menu.addItem(accountWindows)
        menu.addItem(.separator())

        if let sessions = accountWindowDashboards, !sessions.entries.isEmpty {
            let windows = NSMenuItem(title: "Account Window Dashboards", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (id, entry) in sessions.entries.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let name = entry.coordinator.accounts.activeAccountName
                    ?? coordinator.accounts.savedAccounts.first(where: { $0.id == id })?.name ?? "Account window"
                let accountMenu = NSMenu()
                let status = NSMenuItem(title: entry.coordinator.statusPresentation.title, action: nil, keyEquivalent: "")
                status.isEnabled = false
                accountMenu.addItem(status)
                for (title, selector) in [
                    ("Open Dashboard", #selector(openWindowDashboard(_:))),
                    ("Restart & Enable", #selector(restartWindowDashboard(_:))),
                    ("Disable dashboard integration", #selector(disableWindowDashboard(_:))),
                ] {
                    let item = actionItem(title, action: selector)
                    item.representedObject = id
                    item.isEnabled = !entry.coordinator.isPerformingAction
                    accountMenu.addItem(item)
                }
                let accountItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                accountItem.submenu = accountMenu
                submenu.addItem(accountItem)
            }
            windows.submenu = submenu
            menu.addItem(windows)
            menu.addItem(.separator())
        }

        let launchItem = actionItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
        launchItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)
        let completionOpeningItem = actionItem(
            "Open completed chats automatically",
            action: #selector(toggleAutomaticallyOpenCompletedChats)
        )
        completionOpeningItem.state = coordinator.automaticallyOpenCompletedChats ? .on : .off
        menu.addItem(completionOpeningItem)
        let questionOpeningItem = actionItem(
            "Open chats with questions automatically",
            action: #selector(toggleAutomaticallyOpenQuestionChats)
        )
        questionOpeningItem.state = coordinator.automaticallyOpenQuestionChats ? .on : .off
        menu.addItem(questionOpeningItem)
        menu.addItem(actionItem("Copy Diagnostics", action: #selector(copyDiagnostics)))
        menu.addItem(actionItem("Export Prompt Library…", action: #selector(exportPromptLibrary)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Codex Dashboard", action: #selector(quit)))
    }

    @objc private func disableSharedChats() {
        Task { await ChatHandoffService.disable(main: coordinator, windows: accountWindowDashboards) }
    }

    @objc private func enableSharedChats() {
        do {
            try ChatHandoffService.requestActivationWhenIdle()
            coordinator.accounts.setStatusMessage("Shared Chats will connect automatically when the windows are idle.")
        } catch { coordinator.accounts.setStatusMessage(error.localizedDescription) }
    }

    @objc private func openWindowDashboard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = accountWindowDashboards?.entries[id] else { return }
        Task {
            do {
                guard let application = entry.context.applications().first else { throw AccountWindowError.windowNotPresented }
                try await AccountWindowPresenter().present(application, profile: entry.context.profile)
                await entry.coordinator.openChatOverview()
            } catch { entry.coordinator.connectionNotice = error.localizedDescription }
        }
    }

    @objc private func restartWindowDashboard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = accountWindowDashboards?.entries[id] else { return }
        Task { await entry.coordinator.restartCodexAndEnableDashboard() }
    }

    @objc private func disableWindowDashboard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = accountWindowDashboards?.entries[id] else { return }
        Task { await entry.coordinator.disableIntegration() }
    }

    @objc private func openAccountWindow(_ sender: NSMenuItem) {
        guard let accountID = sender.representedObject as? UUID else { return }
        Task { await coordinator.openAccountWindow(accountID) }
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    static func requiresCompatibilityAttention(_ report: CompatibilityReport?) -> Bool {
        guard let report else { return false }
        return report.blockingCount > 0 || report.nonBlockingAttentionCount > 0
    }

    static func statusSymbolName(
        for state: DashboardConnectionState,
        report: CompatibilityReport?,
        dashboardMaintenanceIsEnabled: Bool
    ) -> String {
        if let report, report.blockingCount > 0 { return "exclamationmark.octagon.fill" }
        if let report, report.nonBlockingAttentionCount > 0 { return "exclamationmark.triangle.fill" }
        return state.statusIconIsFilled(dashboardMaintenanceIsEnabled: dashboardMaintenanceIsEnabled)
            ? "rectangle.grid.2x2.fill"
            : "rectangle.grid.2x2"
    }

    private func updateIcon(for state: DashboardConnectionState, report: CompatibilityReport?) {
        let dashboardMaintenanceIsEnabled = coordinator.dashboardRuntime?.maintainsDashboard ?? false
        let symbolName = Self.statusSymbolName(
            for: state,
            report: report,
            dashboardMaintenanceIsEnabled: dashboardMaintenanceIsEnabled
        )
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Codex Dashboard")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = Self.requiresCompatibilityAttention(report)
            ? "Codex Dashboard — \(report?.attentionSummary ?? "compatibility needs attention")"
            : "Codex Dashboard"
    }

    @objc private func openDiagnostics() {
        showDiagnostics()
    }

    @objc private func openChatOverview() {
        Task { await coordinator.openChatOverview() }
    }

    @objc private func restartAndEnable() {
        Task { await coordinator.restartCodexAndEnableDashboard() }
    }

    @objc private func disableIntegration() {
        Task { await coordinator.disableIntegration() }
    }

    @objc private func checkCompatibility() {
        openDiagnostics()
        Task { await coordinator.checkCompatibility() }
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
    }

    @objc private func toggleAutomaticallyOpenQuestionChats() {
        coordinator.automaticallyOpenQuestionChats.toggle()
    }

    @objc private func toggleAutomaticallyOpenCompletedChats() {
        coordinator.automaticallyOpenCompletedChats.toggle()
    }

    @objc private func copyDiagnostics() {
        coordinator.copyDiagnostics()
    }

    @objc private func exportPromptLibrary() {
        Task { await coordinator.exportPromptLibrary() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
