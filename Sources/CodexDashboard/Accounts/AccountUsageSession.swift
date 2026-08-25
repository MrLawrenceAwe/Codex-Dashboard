import Foundation

@MainActor
final class AccountUsageSession {
    private let provider: any AccountUsageProviding
    private let cache: UsageCache
    private var isRefreshing = false
    private var lastCacheSaveAt: Date?

    init(provider: any AccountUsageProviding, cache: UsageCache) {
        self.provider = provider
        self.cache = cache
    }

    func loadCache() -> [UUID: CodexAccountUsageSnapshot] {
        (try? cache.load()) ?? [:]
    }

    func fetchUsage() async throws -> CodexAccountUsage? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        defer { isRefreshing = false }
        return try await provider.usage()
    }

    func reset() async {
        await provider.reset()
    }

    func saveCache(
        _ snapshots: [UUID: CodexAccountUsageSnapshot],
        for accountIDs: Set<UUID>,
        force: Bool = false,
        now: Date = .now
    ) {
        if !force,
           let lastCacheSaveAt,
           now.timeIntervalSince(lastCacheSaveAt) < 5 * 60 {
            return
        }
        do {
            try cache.save(snapshots.filter { accountIDs.contains($0.key) })
            lastCacheSaveAt = now
        } catch {
            // Cache failures must not interfere with account switching or live usage.
        }
    }
}
