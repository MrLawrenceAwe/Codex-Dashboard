import AppKit
import Foundation

extension AppCoordinator {
    func handleAccountPopoverAction() async -> AccountPopoverActionHandlingOutcome {
        guard let dashboardRuntime else { return .unavailable }
        let result = await dashboardRuntime.waitForAccountPopoverAction()
        guard !isPerformingAction else { return .unavailable }
        let action: AccountPopoverAction
        switch result {
        case .action(let value): action = value
        case .timedOut: return .timedOut
        case .unavailable: return .unavailable
        }
        switch action.kind {
        case .updateUsage:
            guard let accountID = action.accountID else { return .unavailable }
            _ = await refreshSavedAccountUsage(accountID, interactionAllowed: true)
        case .refreshInactiveUsage:
            await accounts.refreshInactiveUsage(interactionAllowed: true)
        case .saveCurrentAccount:
            saveCurrentAccount()
        case .switchAccount:
            guard let accountID = action.accountID else { return .unavailable }
            await switchAccount(to: accountID)
        case .addAccount:
            await beginAddingAccount()
        case .forgetAccount:
            guard let accountID = action.accountID else { return .unavailable }
            accounts.deleteAccount(accountID)
        }
        await updateAccountUsageNotifications()
        await publishAccountPopoverSnapshot()
        return .handled
    }

    func refreshAccountStateAfterFileChange() async {
        accounts.refreshState()
        await updateAccountUsageNotifications()
        await publishAccountPopoverSnapshot()
    }

    func refreshAccountState() {
        accounts.refreshState()
    }

    func saveCurrentAccount() {
        if accounts.saveCurrentAccount() {
            Task { await refreshAccountUsage() }
        }
    }

    func switchAccount(to accountID: UUID) async {
        await performAccountTransition { try accounts.activate(accountID) }
    }

    func beginAddingAccount() async {
        await performAccountTransition { try accounts.beginAddingAccount() }
    }

    func dashboardSnapshotPayload() -> DashboardSnapshot {
        DashboardSnapshot(
            threads: threads,
            accountPopover: accounts.popoverSnapshot(isBusy: isPerformingAction)
        )
    }

    private func performAccountTransition(
        transaction: () throws -> AccountTransition
    ) async {
        guard !isPerformingAction, let dashboardRuntime else { return }

        let previousUsageStatus = accounts.activeUsageStatus
        isPerformingAction = true
        defer { isPerformingAction = false }
        refreshGeneration += 1
        await synchronizationGate.cancel()
        await accounts.invalidateUsage()
        do {
            try await loadThreadSnapshot()
        } catch {
            accounts.setStatusMessage(
                "Account change cancelled because active tasks could not be checked. "
                    + error.localizedDescription
            )
            accounts.restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
            return
        }
        guard !threads.contains(where: { $0.runState == .running }) else {
            accounts.setStatusMessage(CodexAccountError.activeTasks.localizedDescription)
            accounts.restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
            return
        }

        accounts.persistUsageCache(force: true)
        let accountTransaction: AccountTransition
        do {
            accountTransaction = try transaction()
        } catch {
            accounts.setStatusMessage(error.localizedDescription)
            accounts.restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
            accounts.refreshState()
            return
        }

        dashboardRuntime.prepareForRestart()
        connectionState = .checking
        connectionError = nil
        let targets: [DevToolsTarget]
        do {
            targets = try await dashboardRuntime.restartCodex()
        } catch let restartError {
            do {
                try accounts.rollback(accountTransaction)
            } catch let rollbackError {
                await accounts.invalidateUsage()
                accounts.refreshState()
                accounts.setStatusMessage(
                    "Codex could not restart, and the account change could not be rolled back. "
                        + rollbackError.localizedDescription
                )
                setFailure(rollbackError, lastKnownState: .codexClosed)
                return
            }
            await accounts.invalidateUsage()
            accounts.refreshState()
            accounts.setStatusMessage("Codex could not restart, so the account change was rolled back.")
            dashboardRuntime.prepareForRestart()
            _ = try? await dashboardRuntime.restartCodex()
            setFailure(restartError, lastKnownState: .codexClosed)
            return
        }

        accounts.refreshState()
        accounts.restoreActiveUsageFromCache()
        accounts.setStatusMessage(
            accounts.activeAccountName.map { "Switched to \($0)." }
                ?? "Sign in to the other account, then save it from Accounts."
        )
        Task { await refreshAccountUsage() }

        // The signed-out renderer intentionally has none of the Codex workspace hosts
        // required by the injected dashboard. Reaching it means the account transition
        // succeeded; mounting resumes through normal polling after sign-in.
        guard accounts.activeAccountID != nil else {
            connectionState = .rendererAvailable
            return
        }

        do {
            try await loadThreadSnapshot()
            try await dashboardRuntime.synchronizeDashboard(
                with: dashboardSnapshotPayload(), on: targets, forceRemount: true
            )
            connectionState = .dashboardMounted
        } catch {
            accounts.setStatusMessage(accounts.activeAccountName.map {
                "Switched to \($0). The dashboard will reconnect when Codex is ready."
            })
            setFailure(error, lastKnownState: .rendererAvailable)
        }
    }

    func refreshAccountUsage() async {
        await accounts.refreshActiveUsage(
            codexIsRunning: dashboardRuntime?.codexIsRunning == true
        )
        await updateAccountUsageNotifications()
        await publishAccountPopoverSnapshot()
    }

    func refreshInactiveAccountUsage() async {
        guard !isPerformingAction else { return }
        await accounts.refreshInactiveUsage()
        await updateAccountUsageNotifications()
        await publishAccountPopoverSnapshot()
    }

    func refreshSavedAccountUsage(
        _ accountID: UUID,
        reportsFailure: Bool = true,
        interactionAllowed: Bool = false
    ) async -> UsageRefreshAuthorization {
        if accountID == accounts.activeAccountID {
            await refreshAccountUsage()
            return .notRequired
        }
        guard !isPerformingAction else { return .notRequired }
        let authorization = await accounts.refreshInactiveAccountUsage(
            accountID,
            reportsFailure: reportsFailure,
            interactionAllowed: interactionAllowed
        )
        await updateAccountUsageNotifications()
        return authorization
    }

    private func publishAccountPopoverSnapshot() async {
        await dashboardRuntime?.synchronizeAccountPopover(
            accounts.popoverSnapshot(isBusy: isPerformingAction)
        )
    }

    func updateAccountUsageNotifications() async {
        await accountUsageNotifier.updateNotifications(
            for: accounts.savedAccounts,
            usageByAccountID: accounts.usageByAccountID
        )
        await phoneUsageNotifier.updateNotifications(
            for: accounts.savedAccounts,
            usageByAccountID: accounts.usageByAccountID
        )
    }

    var phoneNotificationsEnabled: Bool {
        phoneUsageNotifier.isEnabled
    }

    var phoneNotificationTopic: String {
        phoneUsageNotifier.topic
    }

    func setPhoneNotificationsEnabled(_ enabled: Bool) {
        phoneUsageNotifier.setEnabled(enabled)
        phoneNotificationStatusMessage = enabled
            ? "Subscribe to the topic on your phone, then send a test."
            : nil
        objectWillChange.send()
        Task { await updateAccountUsageNotifications() }
    }

    func copyPhoneNotificationTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phoneNotificationTopic, forType: .string)
        phoneNotificationStatusMessage = "Topic copied."
    }

    func generateNewPhoneNotificationTopic() {
        phoneUsageNotifier.generateNewTopic()
        phoneNotificationStatusMessage = "New topic generated. Subscribe to it, then send a test."
        objectWillChange.send()
    }

    func testPhoneNotification() async {
        do {
            try await phoneUsageNotifier.sendTestNotification()
            phoneNotificationStatusMessage = "Test sent. Check your phone."
        } catch {
            phoneNotificationStatusMessage = "Test failed: \(error.localizedDescription)"
        }
    }
}
