import Foundation

// Reports whether retrying requires Keychain authorization, not whether usage was updated.
enum UsageRefreshAuthorization: Equatable {
    case notRequired
    case authorizationRequired
}

@MainActor
final class AccountCoordinator: ObservableObject {
    @Published private(set) var savedAccounts: [SavedAccount] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var usageByAccountID: [UUID: CodexAccountUsageSnapshot] = [:]
    @Published private(set) var activeUsageStatus: CodexAccountUsageStatus = .unavailable
    @Published private(set) var refreshingUsageAccountIDs: Set<UUID> = []
    @Published private(set) var usageErrorsByAccountID: [UUID: String] = [:]

    private let manager: CodexAccountManager
    private let usageSession: AccountUsageSession
    private var usageGeneration = 0
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
        refreshState()
        restoreActiveUsageFromCache()
    }

    var activeAccountName: String? {
        savedAccounts.first { $0.id == activeAccountID }?.name
    }

    func refreshState() {
        do {
            let document = try manager.loadDocument()
            let identifier = try manager.activeCodexAccountID()
            let accounts = document.accounts.sorted {
                if $0.lastUsedAt == $1.lastUsedAt { return $0.name < $1.name }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            if savedAccounts != accounts { savedAccounts = accounts }
            let identityChanged = activeCodexAccountID != identifier
            let savedAccountChanged = activeAccountID != document.activeAccountID
            activeCodexAccountID = identifier
            if savedAccountChanged { activeAccountID = document.activeAccountID }
            if identityChanged || savedAccountChanged {
                usageGeneration += 1
                usageSession.invalidate()
                restoreActiveUsageFromCache()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveCurrentAccount() -> Bool {
        do {
            refreshState()
            let existingUsage = activeUsageStatus.snapshot
            let account = try manager.saveCurrentAccount()
            if let existingUsage { usageByAccountID[account.id] = existingUsage }
            refreshState()
            persistUsageCache(force: true)
            statusMessage = "Saved \(account.name) securely in Keychain."
            if let existingUsage { activeUsageStatus = .available(existingUsage) }
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func deleteAccount(_ accountID: UUID) {
        do {
            try manager.deleteAccount(accountID)
            statusMessage = "Removed the saved account from Keychain."
            usageByAccountID[accountID] = nil
            refreshingUsageAccountIDs.remove(accountID)
            usageErrorsByAccountID[accountID] = nil
            persistUsageCache(force: true)
            refreshState()
            if activeAccountID == nil { activeUsageStatus = .unavailable }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func activate(_ accountID: UUID) throws -> AccountTransition {
        try manager.activate(accountID: accountID)
    }

    func beginAddingAccount() throws -> AccountTransition {
        try manager.beginAddingAccount()
    }

    func rollback(_ transition: AccountTransition) throws {
        try manager.rollback(transition)
    }

    func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    func restoreActiveUsageFromCache() {
        if let activeAccountID, let snapshot = usageByAccountID[activeAccountID] {
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
        // New usage requests already wait for the queued provider reset. Account
        // transitions only need to cancel old requests and reject their results.
        usageSession.invalidate()
    }

    func refreshActiveUsage(codexIsRunning: Bool) async {
        guard codexIsRunning else { return }
        refreshState()
        let generation = usageGeneration
        let accountID = activeAccountID
        let previous = activeUsageStatus.snapshot
        activeUsageStatus = .loading(previous: previous)

        do {
            let usage = try await usageSession.fetchUsage()
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  accountID == activeAccountID
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
                  accountID == activeAccountID
            else { return }
            activeUsageStatus = previous.map(CodexAccountUsageStatus.stale) ?? .unavailable
        }
    }

    func refreshInactiveUsage(interactionAllowed: Bool = false) async {
        let generation = usageGeneration
        let inactiveAccounts = savedAccounts.filter { $0.id != activeAccountID }
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
        if accountID == activeAccountID { return .notRequired }
        guard savedAccounts.contains(where: { $0.id == accountID }) else { return .notRequired }

        let generation = usageGeneration
        refreshingUsageAccountIDs.insert(accountID)
        defer { refreshingUsageAccountIDs.remove(accountID) }
        do {
            let credential = try manager.savedCredential(
                for: accountID, interactionAllowed: interactionAllowed
            )
            let result = try await usageSession.fetchUsage(using: credential, for: accountID)
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  accountID != activeAccountID,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .notRequired }

            try manager.updateSavedCredential(
                result.credential,
                for: accountID,
                interactionAllowed: interactionAllowed
            )
            usageByAccountID[accountID] = CodexAccountUsageSnapshot(
                usage: result.usage,
                fetchedAt: .now
            )
            usageErrorsByAccountID[accountID] = nil
            if persistsUsageCache { persistUsageCache(force: true) }
        } catch CodexAccountError.keychainAuthorizationRequired {
            return .authorizationRequired
        } catch {
            guard !Task.isCancelled,
                  generation == usageGeneration,
                  savedAccounts.contains(where: { $0.id == accountID })
            else { return .notRequired }
            usageErrorsByAccountID[accountID] = error.localizedDescription
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
                let isActive = account.id == activeAccountID
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
                    usageLines: AccountUsageFormatter.lines(
                        for: usageStatus,
                        staleTimestampPrefix: isActive ? "Usage may be stale · updated " : "Updated ",
                        includesAbsoluteDate: false
                    ),
                    isRefreshing: refreshingUsageAccountIDs.contains(account.id),
                    errorMessage: usageErrorsByAccountID[account.id]
                )
            },
            activeAccountID: activeAccountID,
            statusMessage: statusMessage,
            isBusy: isBusy || !refreshingUsageAccountIDs.isEmpty
        )
    }
}
