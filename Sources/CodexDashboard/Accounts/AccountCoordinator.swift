import Foundation

// Reports whether retrying requires Keychain authorization, not whether usage was updated.
enum UsageRefreshAuthorization: Equatable {
    case notRequired
    case authorizationRequired
}

@MainActor
final class AccountCoordinator: ObservableObject {
    @Published private(set) var savedAccounts: [SavedAccount] = []
    @Published private(set) var activeSavedAccountID: UUID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var usageByAccountID: [UUID: CodexAccountUsageSnapshot] = [:]
    @Published private(set) var activeUsageStatus: CodexAccountUsageStatus = .unavailable
    @Published private(set) var refreshingUsageAccountIDs: Set<UUID> = []
    @Published private(set) var usageErrorsByAccountID: [UUID: String] = [:]
    @Published private(set) var accountsRequiringSignIn: Set<UUID> = []

    private let manager: CodexAccountManager
    private let usageSession: AccountUsageSession
    private let accountOperationQueue = DispatchQueue(label: "codex-dashboard.account-operations")
    private var usageGeneration = 0
    private var stateRefresh: (id: UUID, task: Task<(SavedAccountsDocument, String?), Error>)?
    private var activeUsageRefresh: (id: UUID, task: Task<Void, Never>)?
    private var activeCodexAccountID: String?

    init(
        manager: CodexAccountManager,
        usageProvider: any AccountUsageProviding,
        usageCacheStore: (any UsageCaching)? = nil
    ) {
        self.manager = manager
        usageSession = AccountUsageSession(
            provider: usageProvider,
            cache: usageCacheStore ?? manager.usageCacheStore
        )
        usageByAccountID = usageSession.loadCache()
    }

    var activeAccountName: String? {
        savedAccounts.first { $0.id == activeSavedAccountID }?.name
    }

    // Keychain reads (including document migrations) and mutations run away from
    // the main actor, in submission order. The manager's lock also protects callers
    // outside this coordinator while each complete transaction is in progress.
    private func withManager<Value: Sendable>(
        _ operation: @escaping @Sendable (CodexAccountManager) throws -> Value
    ) async throws -> Value {
        let manager = manager
        return try await withCheckedThrowingContinuation { continuation in
            accountOperationQueue.async {
                continuation.resume(with: Result { try operation(manager) })
            }
        }
    }

    func refreshState() async {
        let request = stateRefresh ?? (UUID(), Task { try await withManager { try $0.loadState() } })
        stateRefresh = request
        do {
            let (document, identifier) = try await request.task.value
            guard stateRefresh?.id == request.id else { return }
            stateRefresh = nil
            let accounts = document.accounts.sorted {
                if $0.lastUsedAt == $1.lastUsedAt { return $0.name < $1.name }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            if savedAccounts != accounts { savedAccounts = accounts }
            accountsRequiringSignIn.formIntersection(accounts.map(\.id))
            let identityChanged = activeCodexAccountID != identifier
            let savedAccountChanged = activeSavedAccountID != document.activeAccountID
            activeCodexAccountID = identifier
            if savedAccountChanged { activeSavedAccountID = document.activeAccountID }
            if identityChanged || savedAccountChanged {
                usageGeneration += 1
                usageSession.invalidate()
                restoreActiveUsageFromCache()
            }
        } catch {
            guard stateRefresh?.id == request.id else { return }
            stateRefresh = nil
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveCurrentAccount() async -> Bool {
        do {
            await refreshState()
            let existingUsage = activeUsageStatus.snapshot
            let usageAccountID = activeCodexAccountID
            let account = try await withManager { try $0.saveCurrentAccount() }
            stateRefresh = nil
            if let existingUsage, account.codexAccountID == usageAccountID {
                usageByAccountID[account.id] = existingUsage
            }
            accountsRequiringSignIn.remove(account.id)
            usageErrorsByAccountID[account.id] = nil
            await refreshState()
            persistUsageCache(force: true)
            statusMessage = "Saved \(account.name) securely in Keychain."
            if let existingUsage, account.codexAccountID == usageAccountID,
               activeSavedAccountID == account.id { activeUsageStatus = .available(existingUsage) }
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func synchronizeActiveCredentialAfterFileChange() async -> Bool {
        do {
            await refreshState()
            guard let activeCodexAccountID,
                  savedAccounts.contains(where: { $0.codexAccountID == activeCodexAccountID })
            else { return false }
            let account = try await withManager { try $0.saveCurrentAccount() }
            stateRefresh = nil
            let completedReauthentication = accountsRequiringSignIn.contains(account.id)
            accountsRequiringSignIn.remove(account.id)
            usageErrorsByAccountID[account.id] = nil
            await refreshState()
            persistUsageCache(force: true)
            if completedReauthentication {
                statusMessage = "Signed in as \(account.name). Saved the refreshed credential securely in Keychain."
            }
            return true
        } catch CodexAccountError.noActiveCredential {
            return false
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func removeSavedAccount(_ accountID: UUID) async {
        do {
            try await withManager { try $0.removeSavedAccount(accountID) }
            stateRefresh = nil
            statusMessage = "Removed the saved account from Keychain."
            usageByAccountID[accountID] = nil
            refreshingUsageAccountIDs.remove(accountID)
            usageErrorsByAccountID[accountID] = nil
            accountsRequiringSignIn.remove(accountID)
            persistUsageCache(force: true)
            await refreshState()
            if activeSavedAccountID == nil { activeUsageStatus = .unavailable }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func activate(_ accountID: UUID) async throws -> AccountTransition {
        let transition = try await withManager { try $0.activate(accountID: accountID) }
        stateRefresh = nil
        return transition
    }

    func prepareForSignIn() async throws -> AccountTransition {
        let transition = try await withManager { try $0.prepareForSignIn() }
        stateRefresh = nil
        return transition
    }

    func rollback(_ transition: AccountTransition) async throws {
        try await withManager { try $0.rollback(transition) }
        stateRefresh = nil
    }

    func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    func restoreActiveUsageFromCache() {
        if let activeSavedAccountID, let snapshot = usageByAccountID[activeSavedAccountID] {
            activeUsageStatus = .stale(snapshot)
        } else {
            activeUsageStatus = .unavailable
        }
    }

    func restoreUsageStatus(afterAbortedTransition previousStatus: CodexAccountUsageStatus) {
        activeUsageStatus = previousStatus.snapshot.map(CodexAccountUsageStatus.stale)
            ?? .unavailable
    }

    func invalidateUsage() {
        usageGeneration += 1
        activeUsageRefresh?.task.cancel()
        activeUsageRefresh = nil
        // New usage requests already wait for the queued provider reset. Account
        // transitions only need to cancel old requests and reject their results.
        usageSession.invalidate()
    }

    func refreshActiveUsage(codexIsRunning: Bool) async {
        guard codexIsRunning else { return }
        if let request = activeUsageRefresh {
            await request.task.value
            return
        }
        let id = UUID()
        let task = Task { await performActiveUsageRefresh() }
        activeUsageRefresh = (id, task)
        await task.value
        if activeUsageRefresh?.id == id { activeUsageRefresh = nil }
    }

    private func performActiveUsageRefresh() async {
        await refreshState()
        guard !Task.isCancelled else { return }
        let generation = usageGeneration
        let accountID = activeSavedAccountID
        let previous = activeUsageStatus.snapshot
        activeUsageStatus = .loading(previous: previous)

        do {
            let usage = try await usageSession.fetchUsage()
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  accountID == activeSavedAccountID
            else { return }
            let snapshot = CodexAccountUsageSnapshot(usage: usage, fetchedAt: .now)
            activeUsageStatus = .available(snapshot)
            if let accountID {
                usageByAccountID[accountID] = snapshot
                persistUsageCache()
            }
        } catch {
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  accountID == activeSavedAccountID
            else { return }
            activeUsageStatus = previous.map(CodexAccountUsageStatus.stale) ?? .unavailable
        }
    }

    func refreshInactiveUsage(interactionAllowed: Bool = false) async {
        await refreshState()
        let generation = usageGeneration
        let inactiveAccounts = savedAccounts.filter { $0.id != activeSavedAccountID }
        var shouldPersistUsageCache = false
        defer {
            if shouldPersistUsageCache { persistUsageCache(force: true) }
        }
        for account in inactiveAccounts {
            guard !Task.isCancelled, generation == usageGeneration else { return }
            _ = await refreshInactiveAccountUsage(
                account.id,
                reportsFailure: interactionAllowed,
                interactionAllowed: interactionAllowed,
                persistsUsageCache: false
            )
            shouldPersistUsageCache = true
        }
    }

    func refreshInactiveAccountUsage(
        _ accountID: UUID,
        reportsFailure: Bool = true,
        interactionAllowed: Bool = false,
        persistsUsageCache: Bool = true
    ) async -> UsageRefreshAuthorization {
        await refreshState()
        if accountID == activeSavedAccountID { return .notRequired }
        guard savedAccounts.contains(where: { $0.id == accountID }) else { return .notRequired }

        let generation = usageGeneration
        refreshingUsageAccountIDs.insert(accountID)
        defer { refreshingUsageAccountIDs.remove(accountID) }
        do {
            let credential = try await withManager {
                try $0.savedCredential(for: accountID, interactionAllowed: interactionAllowed)
            }
            guard !Task.isCancelled, generation == usageGeneration,
                  accountID != activeSavedAccountID,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .notRequired }
            let result = try await usageSession.fetchUsage(using: credential, for: accountID)
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  accountID != activeSavedAccountID,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .notRequired }

            try await withManager {
                try $0.updateSavedCredential(result.credential, for: accountID,
                                            interactionAllowed: interactionAllowed)
            }
            guard !Task.isCancelled, generation == usageGeneration,
                  accountID != activeSavedAccountID,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .notRequired }
            usageByAccountID[accountID] = CodexAccountUsageSnapshot(
                usage: result.usage,
                fetchedAt: .now
            )
            usageErrorsByAccountID[accountID] = nil
            accountsRequiringSignIn.remove(accountID)
            if persistsUsageCache { persistUsageCache(force: true) }
        } catch CodexAccountError.keychainAuthorizationRequired {
            return .authorizationRequired
        } catch {
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .notRequired }
            usageErrorsByAccountID[accountID] = error.localizedDescription
            if case CodexAccountUsageError.authenticationExpired = error {
                accountsRequiringSignIn.insert(accountID)
            }
            if reportsFailure,
               let account = savedAccounts.first(where: { $0.id == accountID }) {
                statusMessage = "Could not update usage for \(account.name): \(error.localizedDescription)"
            }
        }
        return .notRequired
    }

    func persistUsageCache(force: Bool = false, now: Date = .now) {
        usageSession.saveCache(
            usageByAccountID,
            for: Set(savedAccounts.map(\.id)),
            force: force,
            now: now
        )
    }

    func popoverSnapshot(isBusy: Bool) -> AccountPopoverSnapshot {
        AccountPopoverSnapshot(
            accounts: savedAccounts.map { account in
                let isActive = account.id == activeSavedAccountID
                let usageStatus: CodexAccountUsageStatus
                if isActive {
                    usageStatus = activeUsageStatus
                } else if let snapshot = usageByAccountID[account.id] {
                    usageStatus = .stale(snapshot)
                } else {
                    usageStatus = .unavailable
                }
                return AccountPopoverItem(
                    id: account.id,
                    name: account.name,
                    isActive: isActive,
                    usageRows: AccountUsageFormatter.rows(
                        for: usageStatus,
                        staleTimestampPrefix: isActive ? "Usage may be stale · updated " : "Updated ",
                        includesAbsoluteDate: false
                    ),
                    isRefreshing: refreshingUsageAccountIDs.contains(account.id),
                    requiresSignIn: accountsRequiringSignIn.contains(account.id),
                    errorMessage: usageErrorsByAccountID[account.id]
                )
            },
            activeAccountID: activeSavedAccountID,
            statusMessage: statusMessage,
            isBusy: isBusy || !refreshingUsageAccountIDs.isEmpty,
            usageBlockage: AccountUsageFormatter.blockage(for: activeUsageStatus)
        )
    }
}
