import Foundation

extension DashboardCoordinator {
    var activeAccountName: String? {
        accountProfiles.first { $0.id == activeAccountProfileID }?.name
    }

    func saveCurrentAccount(named name: String) {
        do {
            let profile = try accountManager.saveCurrentAccount(named: name)
            accountStatusMessage = "Saved \(profile.name) securely in Keychain."
            refreshAccountState()
            Task { await publishAccountSnapshot() }
        } catch {
            accountStatusMessage = error.localizedDescription
        }
    }

    func switchAccount(to profileID: UUID) async {
        await performAccountTransition { try accountManager.activate(profileID: profileID) }
    }

    func beginAddingAccount() async {
        await performAccountTransition { try accountManager.beginAddingAccount() }
    }

    func deleteAccount(_ profileID: UUID) {
        do {
            try accountManager.deleteProfile(profileID)
            accountStatusMessage = "Removed the saved account from Keychain."
            refreshAccountState()
            Task { await publishAccountSnapshot() }
        } catch {
            accountStatusMessage = error.localizedDescription
        }
    }

    func refreshAccountState() {
        do {
            let document = try accountManager.document()
            accountProfiles = document.profiles.sorted {
                if $0.lastUsedAt == $1.lastUsedAt { return $0.name < $1.name }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            activeAccountProfileID = document.activeProfileID
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
            guard let profileID = action.profileID else {
                accountStatusMessage = CodexAccountError.invalidProfile.localizedDescription
                return
            }
            await switchAccount(to: profileID)
        }
    }

    func dashboardSnapshotPayload() -> DashboardSnapshotPayload {
        DashboardSnapshotPayload(
            threads: threads,
            accounts: accountProfiles.map {
                DashboardAccountPayload(
                    id: $0.id.uuidString,
                    name: $0.name,
                    isActive: $0.id == activeAccountProfileID
                )
            },
            activeAccountID: activeAccountProfileID?.uuidString,
            accountStatusMessage: accountStatusMessage
        )
    }

    private func performAccountTransition(
        transaction: () throws -> CodexAccountTransaction
    ) async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        guard !threads.contains(where: { $0.runState == .running }) else {
            accountStatusMessage = CodexAccountError.activeTasks.localizedDescription
            await publishAccountSnapshot()
            return
        }

        isPerformingAction = true
        refreshGeneration += 1
        await synchronizationGate.cancel()
        let accountTransaction: CodexAccountTransaction
        do {
            accountTransaction = try transaction()
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
            refreshAccountState()
            accountStatusMessage = "Codex could not restart, so the account change was rolled back."
            dashboardRuntime.prepareForRestart()
            _ = try? await dashboardRuntime.restartCodex()
            isPerformingAction = false
            setFailure(error, lastKnownState: .codexClosed)
            return
        }

        refreshAccountState()
        accountStatusMessage = activeAccountName.map { "Switched to \($0)." }
            ?? "Sign in to the other account, then save it from Accounts."

        // The signed-out renderer intentionally has none of the Codex workspace hosts
        // required by the injected dashboard. Reaching it means the account transition
        // succeeded; mounting resumes through normal polling after sign-in.
        guard activeAccountProfileID != nil else {
            isPerformingAction = false
            setConnectionState(.rendererReady)
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
            setFailure(error, lastKnownState: .rendererReady)
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
}
