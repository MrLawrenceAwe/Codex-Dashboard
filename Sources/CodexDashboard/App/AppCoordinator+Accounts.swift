import Foundation

enum SavedAccountUsageRefreshOutcome: Equatable {
    case completed
    case authorizationRequired
}

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
        case .updateSignedOutUsage:
            for account in savedAccounts where account.id != activeAccountID {
                _ = await refreshSavedAccountUsage(account.id, interactionAllowed: true)
            }
        case .saveCurrentAccount:
            saveCurrentAccount()
        case .switchAccount:
            guard let accountID = action.accountID else { return .unavailable }
            await switchAccount(to: accountID)
        case .addAccount:
            await beginAddingAccount()
        case .forgetAccount:
            guard let accountID = action.accountID else { return .unavailable }
            deleteAccount(accountID)
        }
        await publishSnapshotIfMaintainedForAccounts()
        return .handled
    }

    func refreshAccountStateAfterFileChange() async {
        refreshAccountState()
        await publishSnapshotIfMaintainedForAccounts()
    }

    private func publishSnapshotIfMaintainedForAccounts() async {
        guard let dashboardRuntime, dashboardRuntime.maintainsDashboard else { return }
        let targets = await dashboardRuntime.rendererTargets()
        guard !targets.isEmpty else { return }
        try? await dashboardRuntime.synchronizeDashboard(
            with: dashboardSnapshotPayload(),
            on: targets,
            forceRemount: false
        )
    }

    var activeAccountName: String? {
        savedAccounts.first { $0.id == activeAccountID }?.name
    }

    func saveCurrentAccount() {
        do {
            let existingUsage = activeAccountUsageStatus.snapshot
            let account = try accountManager.saveCurrentAccount()
            if let existingUsage { usageByAccountID[account.id] = existingUsage }
            persistAccountUsageCache(force: true)
            accountStatusMessage = "Saved \(account.name) securely in Keychain."
            refreshAccountState()
            if let existingUsage { activeAccountUsageStatus = .available(existingUsage) }
            Task { await refreshAccountUsage() }
        } catch {
            accountStatusMessage = error.localizedDescription
        }
    }

    func switchAccount(to accountID: UUID) async {
        await performAccountTransition { try accountManager.activate(accountID: accountID) }
    }

    func beginAddingAccount() async {
        await performAccountTransition { try accountManager.beginAddingAccount() }
    }

    func deleteAccount(_ accountID: UUID) {
        do {
            try accountManager.deleteAccount(accountID)
            accountStatusMessage = "Removed the saved account from Keychain."
            usageByAccountID[accountID] = nil
            refreshingUsageAccountIDs.remove(accountID)
            usageErrorsByAccountID[accountID] = nil
            persistAccountUsageCache(force: true)
            refreshAccountState()
            if activeAccountID == nil { activeAccountUsageStatus = .unavailable }
        } catch {
            accountStatusMessage = error.localizedDescription
        }
    }

    func refreshAccountState() {
        do {
            let document = try accountManager.document()
            let accounts = document.accounts.sorted {
                if $0.lastUsedAt == $1.lastUsedAt { return $0.name < $1.name }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            if savedAccounts != accounts { savedAccounts = accounts }
            if activeAccountID != document.activeAccountID {
                activeAccountID = document.activeAccountID
            }
        } catch {
            accountStatusMessage = error.localizedDescription
        }
    }

    func dashboardSnapshotPayload() -> DashboardSnapshot {
        DashboardSnapshot(threads: threads, accountPopover: accountPopoverSnapshot())
    }

    private func accountPopoverSnapshot() -> AccountPopoverSnapshot {
        AccountPopoverSnapshot(
            accounts: savedAccounts.map { account in
                let isActive = account.id == activeAccountID
                let usageStatus: CodexAccountUsageStatus
                if isActive {
                    usageStatus = activeAccountUsageStatus
                } else if let snapshot = usageByAccountID[account.id] {
                    usageStatus = .stale(snapshot)
                } else {
                    usageStatus = .unavailable
                }
                return AccountPopoverItem(
                    id: account.id,
                    name: account.name,
                    isActive: isActive,
                    usageLines: AccountPopoverUsageFormatter.titles(
                        for: usageStatus,
                        staleLabel: isActive ? "Usage may be stale" : "Cached usage"
                    ),
                    isRefreshing: refreshingUsageAccountIDs.contains(account.id),
                    errorMessage: usageErrorsByAccountID[account.id]
                )
            },
            activeAccountID: activeAccountID,
            statusMessage: accountStatusMessage,
            isBusy: isPerformingAction || !refreshingUsageAccountIDs.isEmpty
        )
    }

    private func performAccountTransition(
        transaction: () throws -> AccountTransition
    ) async {
        guard !isPerformingAction, let dashboardRuntime else { return }

        let previousUsageStatus = activeAccountUsageStatus
        isPerformingAction = true
        refreshGeneration += 1
        await synchronizationGate.cancel()
        await accountUsageSession.reset()
        do {
            try await loadThreadSnapshot()
        } catch {
            accountStatusMessage =
                "Account change cancelled because active tasks could not be checked. "
                    + error.localizedDescription
            restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
            isPerformingAction = false
            return
        }
        guard !threads.contains(where: { $0.runState == .running }) else {
            accountStatusMessage = CodexAccountError.activeTasks.localizedDescription
            restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
            isPerformingAction = false
            return
        }

        persistAccountUsageCache(force: true)
        let accountTransaction: AccountTransition
        do {
            accountTransaction = try transaction()
        } catch {
            accountStatusMessage = error.localizedDescription
            restoreUsageStatus(afterAbortedTransition: previousUsageStatus)
            isPerformingAction = false
            refreshAccountState()
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
                try accountManager.rollback(accountTransaction)
            } catch let rollbackError {
                await accountUsageSession.reset()
                refreshAccountState()
                accountStatusMessage =
                    "Codex could not restart, and the account change could not be rolled back. "
                        + rollbackError.localizedDescription
                isPerformingAction = false
                setFailure(rollbackError, lastKnownState: .codexClosed)
                return
            }
            await accountUsageSession.reset()
            refreshAccountState()
            accountStatusMessage = "Codex could not restart, so the account change was rolled back."
            dashboardRuntime.prepareForRestart()
            _ = try? await dashboardRuntime.restartCodex()
            isPerformingAction = false
            setFailure(restartError, lastKnownState: .codexClosed)
            return
        }

        refreshAccountState()
        if let accountID = activeAccountID,
           let snapshot = usageByAccountID[accountID] {
            activeAccountUsageStatus = .stale(snapshot)
        } else {
            activeAccountUsageStatus = .unavailable
        }
        accountStatusMessage =
            activeAccountName.map { "Switched to \($0)." }
                ?? "Sign in to the other account, then save it from Accounts."
        Task { await refreshAccountUsage() }

        // The signed-out renderer intentionally has none of the Codex workspace hosts
        // required by the injected dashboard. Reaching it means the account transition
        // succeeded; mounting resumes through normal polling after sign-in.
        guard activeAccountID != nil else {
            isPerformingAction = false
            connectionState = .rendererAvailable
            return
        }

        do {
            try await loadThreadSnapshot()
            try await dashboardRuntime.synchronizeDashboard(
                with: dashboardSnapshotPayload(), on: targets, forceRemount: true
            )
            connectionState = .dashboardMounted
            isPerformingAction = false
        } catch {
            isPerformingAction = false
            accountStatusMessage = activeAccountName.map {
                "Switched to \($0). The dashboard will reconnect when Codex is ready."
            }
            setFailure(error, lastKnownState: .rendererAvailable)
        }
    }

    private func restoreUsageStatus(
        afterAbortedTransition previousStatus: CodexAccountUsageStatus
    ) {
        activeAccountUsageStatus = previousStatus.snapshot.map(CodexAccountUsageStatus.stale)
            ?? .unavailable
    }

    func refreshAccountUsage() async {
        guard dashboardRuntime?.codexIsRunning == true else { return }
        let generation = refreshGeneration
        let accountID = activeAccountID
        let previous = activeAccountUsageStatus.snapshot
        activeAccountUsageStatus = .loading(previous: previous)

        do {
            let usage = try await accountUsageSession.fetchUsage()
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  accountID == activeAccountID
            else { return }
            let snapshot = CodexAccountUsageSnapshot(usage: usage, fetchedAt: .now)
            activeAccountUsageStatus = .available(snapshot)
            if let accountID {
                usageByAccountID[accountID] = snapshot
                persistAccountUsageCache()
            }
        } catch {
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  accountID == activeAccountID
            else { return }
            activeAccountUsageStatus = previous.map(CodexAccountUsageStatus.stale) ?? .unavailable
        }
    }

    func refreshInactiveAccountUsage() async {
        guard !isPerformingAction else { return }
        for account in savedAccounts where account.id != activeAccountID {
            guard !Task.isCancelled else { return }
            _ = await refreshSavedAccountUsage(account.id, reportsFailure: false)
        }
    }

    func refreshSavedAccountUsage(
        _ accountID: UUID,
        reportsFailure: Bool = true,
        interactionAllowed: Bool = false
    ) async -> SavedAccountUsageRefreshOutcome {
        if accountID == activeAccountID {
            await refreshAccountUsage()
            return .completed
        }
        guard !isPerformingAction,
              savedAccounts.contains(where: { $0.id == accountID })
        else { return .completed }

        let generation = refreshGeneration
        refreshingUsageAccountIDs.insert(accountID)
        defer { refreshingUsageAccountIDs.remove(accountID) }
        do {
            let credential = try interactionAllowed
                ? accountManager.savedCredentialAllowingUserInteraction(for: accountID)
                : accountManager.savedCredentialWithoutUserInteraction(for: accountID)
            guard let result = try await accountUsageSession.fetchUsage(using: credential) else {
                return .completed
            }
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  accountID != activeAccountID,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .completed }

            try accountManager.updateSavedCredential(
                result.credential,
                for: accountID,
                interactionAllowed: interactionAllowed
            )
            usageByAccountID[accountID] = CodexAccountUsageSnapshot(
                usage: result.usage,
                fetchedAt: .now
            )
            usageErrorsByAccountID[accountID] = nil
            persistAccountUsageCache(force: true)
        } catch CodexAccountError.keychainAuthorizationRequired {
            return .authorizationRequired
        } catch {
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .completed }
            usageErrorsByAccountID[accountID] = error.localizedDescription
            if reportsFailure,
               let account = savedAccounts.first(where: { $0.id == accountID }) {
                accountStatusMessage = "Could not update usage for \(account.name): \(error.localizedDescription)"
            }
        }
        return .completed
    }

    func persistAccountUsageCache(force: Bool = false, now: Date = .now) {
        let accountIDs = Set(savedAccounts.map(\.id))
        accountUsageSession.saveCache(
            usageByAccountID,
            for: accountIDs,
            force: force,
            now: now
        )
    }
}
