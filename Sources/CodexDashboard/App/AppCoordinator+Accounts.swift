import AppKit
import Foundation

extension AppCoordinator {
    func handleAccountPopoverAction() async -> AccountPopoverActionHandlingOutcome {
        guard !isPerformingAction, let dashboardRuntime else { return .unavailable }
        let result = await dashboardRuntime.pollAccountPopoverAction()
        let action: AccountPopoverAction
        switch result {
        case .action(let value): action = value
        case .empty: return .empty
        case .unavailable: return .unavailable
        }
        guard !isPerformingAction else {
            accounts.setStatusMessage("Another dashboard action is in progress. Try again when it finishes.")
            await dashboardRuntime.completeAccountPopoverAction(action, snapshot: accounts.popoverSnapshot(isBusy: true))
            return .handled
        }
        let presentationAlreadyUpdated: Bool
        switch action.kind {
        case .refreshUsage:
            if let accountID = action.accountID {
                _ = await refreshSavedAccountUsage(accountID, interactionAllowed: true)
            } else {
                await refreshAccountUsage()
            }
            presentationAlreadyUpdated = true
        case .refreshInactiveUsage:
            await refreshInactiveAccountUsage(interactionAllowed: true)
            presentationAlreadyUpdated = true
        case .saveCurrentAccount:
            await saveCurrentAccount()
            presentationAlreadyUpdated = false
        case .openAccountWindow:
            guard let accountID = action.accountID else { return .unavailable }
            await openAccountWindow(accountID)
            presentationAlreadyUpdated = false
        case .switchAccount:
            guard let accountID = action.accountID else { return .unavailable }
            await switchAccount(to: accountID)
            presentationAlreadyUpdated = false
        case .restartForSignIn:
            await prepareForSignIn()
            presentationAlreadyUpdated = false
        case .removeSavedAccount:
            guard let accountID = action.accountID else { return .unavailable }
            await accounts.removeSavedAccount(accountID)
            presentationAlreadyUpdated = false
        }
        await dashboardRuntime.completeAccountPopoverAction(
            action, snapshot: accounts.popoverSnapshot(isBusy: isPerformingAction)
        )
        if !presentationAlreadyUpdated {
            await updateAccountPresentation()
        }
        return .handled
    }

    func refreshAccountStateAfterFileChange() async {
        await accounts.refreshState()
        if await accounts.synchronizeActiveCredentialAfterFileChange() {
            await refreshAccountUsage()
            return
        }
        await updateAccountUsageNotifications()
        await publishAccountPopoverSnapshot()
    }

    func refreshAccountState() async {
        await accounts.refreshState()
    }

    func saveCurrentAccount() async {
        if await accounts.saveCurrentAccount() {
            Task { await refreshAccountUsage() }
        }
    }

    func openAccountWindow(_ accountID: UUID) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await accountWindows.open(accountID: accountID, accounts: accounts)
            accounts.setStatusMessage("Opened the account window. Dashboard connects automatically.")
        } catch {
            accounts.setStatusMessage(error.localizedDescription)
        }
    }

    func switchAccount(to accountID: UUID) async {
        if accounts.isAccountWindow {
            await openAccountWindow(accountID)
            return
        }
        if ChatHandoffService.isEnabled {
            guard ChatHandoffService.supportsAccountSwitch else {
                accounts.setStatusMessage("Use Update Shared Chats in the Dashboard menu to enable Switch.")
                return
            }
            guard let account = accounts.savedAccounts.first(where: { $0.id == accountID }),
                  let identity = account.codexAccountID, ChatHandoffService.permitsAccountSwitch(to: identity) else {
                accounts.setStatusMessage("This account is unavailable on the shared chat connection.")
                return
            }
            await performAccountTransition(applyAfterQuit: true) {
                try ChatHandoffService.prepareMainWindowForAccountSwitch()
                return try await self.accounts.activate(accountID, expectedAccountIdentifier: identity)
            }
        } else {
            await performAccountTransition { try await self.accounts.activate(accountID) }
        }
    }

    func prepareForSignIn() async {
        if ChatHandoffService.isEnabled {
            accounts.setStatusMessage("Disable Shared Chats from the Dashboard menu before adding another account.")
            return
        }
        guard !accounts.isAccountWindow else {
            accounts.setStatusMessage("Add saved accounts in the main window. To renew this window’s sign-in, use Codex’s own account menu.")
            return
        }
        await performAccountTransition { try await self.accounts.prepareForSignIn() }
    }

    func dashboardSnapshotPayload() -> DashboardSnapshot {
        DashboardSnapshot(
            threads: threads,
            accountPopover: accounts.popoverSnapshot(isBusy: isPerformingAction)
        )
    }

    private func performAccountTransition(
        applyAfterQuit: Bool = false,
        transaction: @escaping () async throws -> AccountTransition
    ) async {
        guard !isPerformingAction else {
            accounts.setStatusMessage("Another dashboard action is in progress. Try again when it finishes.")
            return
        }
        guard let dashboardRuntime else { return }

        let previousUsageStatus = accounts.activeUsageStatus
        isPerformingAction = true
        defer { isPerformingAction = false }
        refreshGeneration += 1
        await synchronizationCoalescer.cancelAndWait()
        await dashboardRuntime.waitForReviewOperations()
        accounts.invalidateUsage()
        do {
            _ = try await refreshThreadState()
        } catch {
            accounts.setStatusMessage(
                "Account change cancelled because active chats could not be checked. "
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
        var accountTransaction: AccountTransition?
        if !applyAfterQuit {
            do {
                accountTransaction = try await transaction()
            } catch {
                accounts.setStatusMessage(error.localizedDescription)
                accounts.restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
                await accounts.refreshState()
                return
            }
        }

        dashboardRuntime.prepareForRestart()
        connectionState = .checking
        connectionError = nil
        let targets: [DevToolsTarget]
        do {
            if applyAfterQuit {
                targets = try await dashboardRuntime.restartCodex(activate: true) {
                    accountTransaction = try await transaction()
                }
            } else {
                targets = try await dashboardRuntime.restartCodex(activate: true)
            }
        } catch let restartError {
            do {
                if let accountTransaction { try await accounts.rollback(accountTransaction) }
            } catch let rollbackError {
                accounts.invalidateUsage()
                await accounts.refreshState()
                accounts.setStatusMessage(
                    "Codex could not restart, and the account change could not be rolled back. "
                        + rollbackError.localizedDescription
                )
                setFailure(rollbackError, lastKnownState: .codexClosed)
                return
            }
            accounts.invalidateUsage()
            await accounts.refreshState()
            accounts.setStatusMessage(accountTransaction == nil
                ? restartError.localizedDescription
                : "Codex could not restart, so the account change was rolled back.")
            if accountTransaction != nil || !dashboardRuntime.codexIsRunning {
                dashboardRuntime.prepareForRestart()
                _ = try? await dashboardRuntime.restartCodex(activate: true)
            }
            setFailure(restartError, lastKnownState: .codexClosed)
            return
        }

        await accounts.refreshState()
        accounts.restoreActiveUsageFromCache()
        accounts.setStatusMessage(
            accounts.activeAccountName.map { "Switched to \($0)." }
                ?? "Sign in to the other account, then save it from Accounts."
        )
        Task { await refreshAccountUsage() }

        // The signed-out renderer intentionally has none of the Codex workspace hosts
        // required by the injected dashboard. Reaching it means the account transition
        // succeeded; mounting resumes through normal polling after sign-in.
        guard accounts.activeSavedAccountID != nil else {
            connectionState = .rendererAvailable
            return
        }

        do {
            // The preflight snapshot is fresh and contains no running chats.
            // Mount it immediately; normal polling refreshes the new process state.
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
        await updateAccountPresentation()
    }

    func refreshInactiveAccountUsage(interactionAllowed: Bool = false) async {
        guard !isPerformingAction else { return }
        await accounts.refreshInactiveUsage(interactionAllowed: interactionAllowed)
        await updateAccountPresentation()
    }

    func refreshSavedAccountUsage(
        _ accountID: UUID,
        reportsFailure: Bool = true,
        interactionAllowed: Bool = false
    ) async -> UsageRefreshAuthorization {
        await accounts.refreshState()
        if accountID == accounts.activeSavedAccountID {
            await refreshAccountUsage()
            return .notRequired
        }
        guard !isPerformingAction else { return .notRequired }
        let authorization = await accounts.refreshInactiveAccountUsage(
            accountID,
            reportsFailure: reportsFailure,
            interactionAllowed: interactionAllowed
        )
        await updateAccountPresentation()
        return authorization
    }

    func refreshUsageForScheduledNotification(
        _ accountID: UUID
    ) async -> CodexAccountUsageSnapshot? {
        let snapshot = await notificationUsageRefresher.refresh(
            accountID, codexIsRunning: dashboardRuntime?.codexIsRunning == true
        )
        if snapshot != nil {
            Task { [weak self] in await self?.publishAccountPopoverSnapshot() }
        }
        return snapshot
    }

    private func updateAccountPresentation() async {
        await updateAccountUsageNotifications()
        await publishAccountPopoverSnapshot()
    }

    private func publishAccountPopoverSnapshot() async {
        await dashboardRuntime?.synchronizeAccountPopover(
            accounts.popoverSnapshot(isBusy: isPerformingAction)
        )
    }

    func updateAccountUsageNotifications() async {
        await desktopUsageNotifier.updateNotifications(
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
