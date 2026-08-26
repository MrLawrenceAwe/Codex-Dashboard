import Foundation

enum SavedAccountUsageRefreshOutcome: Equatable {
    case completed
    case authorizationRequired
}

extension AppCoordinator {
    func handleAccountPopoverAction() async {
        guard !isPerformingAction,
              let action = await dashboardRuntime?.consumeAccountPopoverAction()
        else { return }
        switch action.kind {
        case .updateUsage:
            guard let accountID = action.accountID else { return }
            _ = await refreshSavedAccountUsage(accountID, interactionAllowed: true)
        case .updateSignedOutUsage:
            for account in savedAccounts where account.id != activeAccountID {
                _ = await refreshSavedAccountUsage(account.id, interactionAllowed: true)
            }
        case .saveCurrentAccount:
            saveCurrentAccount()
        case .switchAccount:
            guard let accountID = action.accountID else { return }
            await switchAccount(to: accountID)
        case .addAccount:
            await beginAddingAccount()
        case .forgetAccount:
            guard let accountID = action.accountID else { return }
            deleteAccount(accountID)
        }
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
            if let existingUsage { updateUsage(existingUsage, for: account.id) }
            persistAccountUsageCache(force: true)
            setAccountStatus("Saved \(account.name) securely in Keychain.")
            refreshAccountState()
            if let existingUsage { setActiveAccountUsageStatus(.available(existingUsage)) }
            Task { await refreshAccountUsage() }
        } catch {
            setAccountStatus(error.localizedDescription)
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
            setAccountStatus("Removed the saved account from Keychain.")
            updateUsage(nil, for: accountID)
            setRefreshingUsage(false, for: accountID)
            setUsageError(nil, for: accountID)
            persistAccountUsageCache(force: true)
            refreshAccountState()
            if activeAccountID == nil { setActiveAccountUsageStatus(.unavailable) }
        } catch {
            setAccountStatus(error.localizedDescription)
        }
    }

    func refreshAccountState() {
        do {
            let document = try accountManager.document()
            let accounts = document.accounts.sorted {
                if $0.lastUsedAt == $1.lastUsedAt { return $0.name < $1.name }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            setAccountState(accounts: accounts, activeAccountID: document.activeAccountID)
        } catch {
            setAccountStatus(error.localizedDescription)
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
        guard !threads.contains(where: { $0.runState == .running }) else {
            setAccountStatus(CodexAccountError.activeTasks.localizedDescription)
            return
        }

        setPerformingAction(true)
        advanceRefreshGeneration()
        persistAccountUsageCache(force: true)
        await synchronizationGate.cancel()
        let accountTransaction: AccountTransition
        do {
            accountTransaction = try transaction()
            await accountUsageSession.reset()
        } catch {
            setAccountStatus(error.localizedDescription)
            setPerformingAction(false)
            refreshAccountState()
            return
        }

        dashboardRuntime.prepareForRestart()
        setConnectionState(.checking)
        setConnectionError(nil)
        let targets: [DevToolsTarget]
        do {
            targets = try await dashboardRuntime.restartCodex()
        } catch let restartError {
            do {
                try accountManager.rollback(accountTransaction)
            } catch let rollbackError {
                await accountUsageSession.reset()
                refreshAccountState()
                setAccountStatus(
                    "Codex could not restart, and the account change could not be rolled back. "
                        + rollbackError.localizedDescription
                )
                setPerformingAction(false)
                setFailure(rollbackError, lastKnownState: .codexClosed)
                return
            }
            await accountUsageSession.reset()
            refreshAccountState()
            setAccountStatus("Codex could not restart, so the account change was rolled back.")
            dashboardRuntime.prepareForRestart()
            _ = try? await dashboardRuntime.restartCodex()
            setPerformingAction(false)
            setFailure(restartError, lastKnownState: .codexClosed)
            return
        }

        refreshAccountState()
        if let accountID = activeAccountID,
           let snapshot = usageByAccountID[accountID] {
            setActiveAccountUsageStatus(.stale(snapshot))
        } else {
            setActiveAccountUsageStatus(.unavailable)
        }
        setAccountStatus(
            activeAccountName.map { "Switched to \($0)." }
                ?? "Sign in to the other account, then save it from Accounts."
        )
        Task { await refreshAccountUsage() }

        // The signed-out renderer intentionally has none of the Codex workspace hosts
        // required by the injected dashboard. Reaching it means the account transition
        // succeeded; mounting resumes through normal polling after sign-in.
        guard activeAccountID != nil else {
            setPerformingAction(false)
            setConnectionState(.rendererAvailable)
            return
        }

        do {
            try await loadThreadSnapshot()
            try await dashboardRuntime.synchronizeDashboard(
                with: dashboardSnapshotPayload(), on: targets, forceRemount: true
            )
            setConnectionState(.dashboardMounted)
            setPerformingAction(false)
        } catch {
            setPerformingAction(false)
            setAccountStatus(activeAccountName.map {
                "Switched to \($0). The dashboard will reconnect when Codex is ready."
            })
            setFailure(error, lastKnownState: .rendererAvailable)
        }
    }

    func refreshAccountUsage() async {
        guard dashboardRuntime?.codexIsRunning == true else { return }
        let generation = refreshGeneration
        let accountID = activeAccountID
        let previous = activeAccountUsageStatus.snapshot
        setActiveAccountUsageStatus(.loading(previous: previous))

        do {
            guard let usage = try await accountUsageSession.fetchUsage() else { return }
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  accountID == activeAccountID
            else { return }
            let snapshot = CodexAccountUsageSnapshot(usage: usage, fetchedAt: .now)
            setActiveAccountUsageStatus(.available(snapshot))
            if let accountID {
                updateUsage(snapshot, for: accountID)
                persistAccountUsageCache()
            }
        } catch {
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  accountID == activeAccountID
            else { return }
            setActiveAccountUsageStatus(
                previous.map(CodexAccountUsageStatus.stale) ?? .unavailable
            )
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
              savedAccounts.contains(where: { $0.id == accountID }),
              refreshingUsageAccountIDs.isEmpty
        else { return .completed }

        let generation = refreshGeneration
        setRefreshingUsage(true, for: accountID)
        defer { setRefreshingUsage(false, for: accountID) }
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
            updateUsage(
                CodexAccountUsageSnapshot(usage: result.usage, fetchedAt: .now),
                for: accountID
            )
            setUsageError(nil, for: accountID)
            persistAccountUsageCache(force: true)
        } catch CodexAccountError.keychainAuthorizationRequired {
            return .authorizationRequired
        } catch {
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .completed }
            setUsageError(error.localizedDescription, for: accountID)
            if reportsFailure,
               let account = savedAccounts.first(where: { $0.id == accountID }) {
                setAccountStatus("Could not update usage for \(account.name): \(error.localizedDescription)")
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
