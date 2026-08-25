import Foundation

extension DashboardCoordinator {
    var activeAccountName: String? {
        accountProfiles.first { $0.id == activeAccountProfileID }?.name
    }

    func saveCurrentAccount(named name: String) {
        do {
            let existingUsage = activeAccountUsageStatus.snapshot
            let profile = try accountManager.saveCurrentAccount(named: name)
            if let existingUsage { accountUsageByProfileID[profile.id] = existingUsage }
            persistAccountUsageCache(force: true)
            accountStatusMessage = "Saved \(profile.name) securely in Keychain."
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
            accountUsageByProfileID[profileID] = nil
            persistAccountUsageCache(force: true)
            refreshAccountState()
            if activeAccountProfileID == nil { activeAccountUsageStatus = .unavailable }
            Task { await publishAccountSnapshot() }
        } catch {
            accountStatusMessage = error.localizedDescription
        }
    }

    func refreshAccountState() {
        do {
            let document = try accountManager.document()
            let profiles = document.profiles.sorted {
                if $0.lastUsedAt == $1.lastUsedAt { return $0.name < $1.name }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            if accountProfiles != profiles { accountProfiles = profiles }
            if activeAccountProfileID != document.activeProfileID {
                activeAccountProfileID = document.activeProfileID
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
        persistAccountUsageCache(force: true)
        await synchronizationGate.cancel()
        let accountTransaction: CodexAccountTransaction
        do {
            accountTransaction = try transaction()
            await accountUsageProvider.reset()
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
            await accountUsageProvider.reset()
            refreshAccountState()
            accountStatusMessage = "Codex could not restart, so the account change was rolled back."
            dashboardRuntime.prepareForRestart()
            _ = try? await dashboardRuntime.restartCodex()
            isPerformingAction = false
            setFailure(error, lastKnownState: .codexClosed)
            return
        }

        refreshAccountState()
        if let profileID = activeAccountProfileID,
           let snapshot = accountUsageByProfileID[profileID] {
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

    func refreshAccountUsage() async {
        guard !isRefreshingAccountUsage, dashboardRuntime?.codexIsRunning == true else { return }
        isRefreshingAccountUsage = true
        defer { isRefreshingAccountUsage = false }
        let generation = refreshGeneration
        let profileID = activeAccountProfileID
        let previous = activeAccountUsageStatus.snapshot
        activeAccountUsageStatus = .loading(previous: previous)

        do {
            let usage = try await accountUsageProvider.usage()
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  profileID == activeAccountProfileID
            else { return }
            let snapshot = CodexAccountUsageSnapshot(usage: usage, fetchedAt: .now)
            activeAccountUsageStatus = .available(snapshot)
            if let profileID {
                accountUsageByProfileID[profileID] = snapshot
                persistAccountUsageCache()
            }
        } catch {
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  profileID == activeAccountProfileID
            else { return }
            activeAccountUsageStatus = previous.map(CodexAccountUsageStatus.stale)
                ?? .unavailable
        }
    }

    func persistAccountUsageCache(force: Bool = false, now: Date = .now) {
        if !force,
           let lastUsageCacheSaveAt,
           now.timeIntervalSince(lastUsageCacheSaveAt) < 5 * 60 {
            return
        }
        let profileIDs = Set(accountProfiles.map(\.id))
        let snapshots = accountUsageByProfileID.filter { profileIDs.contains($0.key) }
        do {
            try accountUsageCacheStore.save(snapshots)
            lastUsageCacheSaveAt = now
        } catch {
            // Usage cache failures must not interfere with account switching or live usage.
        }
    }
}
