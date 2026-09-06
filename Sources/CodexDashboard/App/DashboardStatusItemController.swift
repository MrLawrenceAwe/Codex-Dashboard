import AppKit
import Combine

@MainActor
final class DashboardStatusItemController: NSObject, NSMenuDelegate {
    private static let autosaveName = "CodexDashboardStatusItem"
    private static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let defaultPreferredPosition = 450

    private let coordinator: AppCoordinator
    private let launchAtLogin: LaunchAtLoginController
    private let showDiagnostics: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private var statusPresentationCancellable: AnyCancellable?

    init(
        coordinator: AppCoordinator,
        launchAtLogin: LaunchAtLoginController,
        showDiagnostics: @escaping @MainActor () -> Void
    ) {
        Self.registerDefaultPosition()
        self.coordinator = coordinator
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
        coordinator.refreshAccountState()
        Task { await coordinator.refreshAccountUsage() }
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusPresentation.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let report = coordinator.compatibilityReport,
           report.blockingCount > 0 || report.warningCount > 0 {
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
            action: #selector(openTaskDashboard)
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
            action: #selector(disableTaskDashboard)
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

    static func requiresCompatibilityAttention(_ report: CompatibilityReport?) -> Bool {
        guard let report else { return false }
        return report.blockingCount > 0 || report.warningCount > 0
    }

    static func statusSymbolName(
        for state: DashboardConnectionState,
        report: CompatibilityReport?,
        dashboardMaintenanceIsEnabled: Bool
    ) -> String {
        if let report, report.blockingCount > 0 { return "exclamationmark.octagon.fill" }
        if let report, report.warningCount > 0 { return "exclamationmark.triangle.fill" }
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

    @objc private func openTaskDashboard() {
        Task { await coordinator.openTaskDashboard() }
    }

    @objc private func restartAndEnable() {
        Task { await coordinator.restartCodexAndEnableDashboard() }
    }

    @objc private func disableTaskDashboard() {
        Task { await coordinator.disableTaskDashboard() }
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
