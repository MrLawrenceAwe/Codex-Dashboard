import Foundation

extension AppCoordinator {
    var activeAccountName: String? {
        savedAccounts.first { $0.id == activeAccountID }?.name
    }

    func saveCurrentAccount(named name: String) {
        do {
            let existingUsage = activeAccountUsageStatus.snapshot
            let account = try accountManager.saveCurrentAccount(named: name)
            if let existingUsage { usageByAccountID[account.id] = existingUsage }
            persistAccountUsageCache(force: true)
            accountStatusMessage = "Saved \(account.name) securely in Keychain."
            refreshAccountState()
            if let existingUsage { activeAccountUsageStatus = .available(existingUsage) }
            Task {
                await publishAccountSnapshot()
                await refreshAccountUsage()
            }
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
            persistAccountUsageCache(force: true)
            refreshAccountState()
            if activeAccountID == nil { activeAccountUsageStatus = .unavailable }
            Task { await publishAccountSnapshot() }
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

    func handleAccountAction(_ action: DashboardAccountAction) async {
        switch action.type {
        case .save:
            guard let name = action.name else {
                accountStatusMessage = CodexAccountError.accountNameRequired.localizedDescription
                return
            }
            saveCurrentAccount(named: name)
        case .add:
            await beginAddingAccount()
        case .switchAccount:
            guard let accountID = action.accountID else {
                accountStatusMessage = CodexAccountError.accountNotFound.localizedDescription
                return
            }
            await switchAccount(to: accountID)
        }
    }

    func dashboardSnapshotPayload() -> DashboardSnapshot {
        DashboardSnapshot(
            threads: threads,
            accounts: savedAccounts.map {
                SavedAccountOption(
                    id: $0.id.uuidString,
                    name: $0.name,
                    isActive: $0.id == activeAccountID
                )
            },
            activeAccountID: activeAccountID?.uuidString,
            accountStatusMessage: accountStatusMessage
        )
    }

    private func performAccountTransition(
        transaction: () throws -> AccountTransition
    ) async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        guard !threads.contains(where: { $0.runState == .running }) else {
            accountStatusMessage = CodexAccountError.activeTasks.localizedDescription
            await publishAccountSnapshot()
            return
        }

        isPerformingAction = true
        refreshGeneration += 1
        persistAccountUsageCache(force: true)
        await synchronizationGate.cancel()
        let accountTransaction: AccountTransition
        do {
            accountTransaction = try transaction()
            await accountUsageSession.reset()
        } catch {
            accountStatusMessage = error.localizedDescription
            isPerformingAction = false
            refreshAccountState()
            return
        }

        dashboardRuntime.prepareForRestart()
        setConnectionState(.checking)
        setConnectionError(nil)
        let targets: [DevToolsTarget]
        do {
            targets = try await dashboardRuntime.restartCodex()
        } catch {
            try? accountManager.rollback(accountTransaction)
            await accountUsageSession.reset()
            refreshAccountState()
            accountStatusMessage = "Codex could not restart, so the account change was rolled back."
            dashboardRuntime.prepareForRestart()
            _ = try? await dashboardRuntime.restartCodex()
            isPerformingAction = false
            setFailure(error, lastKnownState: .codexClosed)
            return
        }

        refreshAccountState()
        if let accountID = activeAccountID,
           let snapshot = usageByAccountID[accountID] {
            activeAccountUsageStatus = .stale(snapshot)
        } else {
            activeAccountUsageStatus = .unavailable
        }
        accountStatusMessage = activeAccountName.map { "Switched to \($0)." }
            ?? "Sign in to the other account, then save it from Accounts."
        Task { await refreshAccountUsage() }

        // The signed-out renderer intentionally has none of the Codex workspace hosts
        // required by the injected dashboard. Reaching it means the account transition
        // succeeded; mounting resumes through normal polling after sign-in.
        guard activeAccountID != nil else {
            isPerformingAction = false
            setConnectionState(.rendererAvailable)
            return
        }

        do {
            try await loadThreadSnapshot()
            try await dashboardRuntime.synchronizeDashboard(
                with: dashboardSnapshotPayload(), on: targets, forceRemount: true
            )
            setConnectionState(.dashboardMounted)
            isPerformingAction = false
        } catch {
            isPerformingAction = false
            accountStatusMessage = activeAccountName.map {
                "Switched to \($0). The dashboard will reconnect when Codex is ready."
            }
            setFailure(error, lastKnownState: .rendererAvailable)
        }
    }

    private func publishAccountSnapshot() async {
        guard !isPerformingAction, let dashboardRuntime, dashboardRuntime.maintainsDashboard else { return }
        let targets = await dashboardRuntime.rendererTargets()
        guard !targets.isEmpty else { return }
        try? await dashboardRuntime.synchronizeDashboard(
            with: dashboardSnapshotPayload(), on: targets, forceRemount: false
        )
    }

    func refreshAccountUsage() async {
        guard dashboardRuntime?.codexIsRunning == true else { return }
        let generation = refreshGeneration
        let accountID = activeAccountID
        let previous = activeAccountUsageStatus.snapshot
        activeAccountUsageStatus = .loading(previous: previous)

        do {
            guard let usage = try await accountUsageSession.fetchUsage() else { return }
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
            activeAccountUsageStatus = previous.map(CodexAccountUsageStatus.stale)
                ?? .unavailable
        }
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
