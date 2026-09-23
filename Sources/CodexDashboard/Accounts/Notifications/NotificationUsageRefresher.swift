import Foundation

@MainActor
final class NotificationUsageRefresher {
    private struct CacheEntry {
        let snapshot: CodexAccountUsageSnapshot
        let expiresAt: Date
    }

    private let accounts: AccountCoordinator
    private let now: () -> Date
    private let reuseInterval: TimeInterval
    private var cachedSnapshots: [UUID: CacheEntry] = [:]
    private var pendingRefreshes: [UUID: Task<CodexAccountUsageSnapshot?, Never>] = [:]

    init(
        accounts: AccountCoordinator,
        reuseInterval: TimeInterval = 60,
        now: @escaping () -> Date = { .now }
    ) {
        self.accounts = accounts
        self.reuseInterval = reuseInterval
        self.now = now
    }

    func refresh(
        _ accountID: UUID, codexIsRunning: Bool
    ) async -> CodexAccountUsageSnapshot? {
        let currentDate = now()
        if let cached = cachedSnapshots[accountID],
           cached.expiresAt > currentDate {
            if let latest = accounts.usageByAccountID[accountID],
               latest.fetchedAt > cached.snapshot.fetchedAt {
                cachedSnapshots[accountID] = CacheEntry(
                    snapshot: latest,
                    expiresAt: currentDate.addingTimeInterval(reuseInterval)
                )
                return latest
            }
            return cached.snapshot
        }
        if let task = pendingRefreshes[accountID] {
            return await task.value
        }

        let task = Task { @MainActor [weak self] in
            await self?.fetchFreshSnapshot(accountID, codexIsRunning: codexIsRunning)
        }
        pendingRefreshes[accountID] = task
        let snapshot = await task.value
        pendingRefreshes[accountID] = nil
        if let snapshot {
            cachedSnapshots[accountID] = CacheEntry(
                snapshot: snapshot,
                expiresAt: now().addingTimeInterval(reuseInterval)
            )
        }
        return snapshot
    }

    private func fetchFreshSnapshot(
        _ accountID: UUID, codexIsRunning: Bool
    ) async -> CodexAccountUsageSnapshot? {
        let previousFetch = accounts.usageByAccountID[accountID]?.fetchedAt
        if accountID == accounts.activeAccountID {
            await accounts.refreshActiveUsage(
                codexIsRunning: codexIsRunning
            )
        } else {
            _ = await accounts.refreshInactiveAccountUsage(
                accountID,
                reportsFailure: false,
                interactionAllowed: false
            )
        }
        guard let snapshot = accounts.usageByAccountID[accountID] else { return nil }
        if let previousFetch, snapshot.fetchedAt <= previousFetch { return nil }
        return snapshot
    }

}
