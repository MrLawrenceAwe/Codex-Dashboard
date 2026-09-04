import Foundation

@MainActor
final class AccountUsageSession {
    private let provider: any AccountUsageProviding
    private let cache: any UsageCaching
    private var activeUsageTask: Task<CodexAccountUsage, Error>?
    private var activeUsageTaskID: UUID?
    private var savedAccountUsageTask: Task<SavedAccountUsageResult, Error>?
    private var savedAccountUsageTaskID: UUID?
    private var resetTask: Task<Void, Never>?
    private var lastCacheSaveAt: Date?

    init(provider: any AccountUsageProviding, cache: any UsageCaching) {
        self.provider = provider
        self.cache = cache
    }

    func loadCache() -> [UUID: CodexAccountUsageSnapshot] {
        (try? cache.load()) ?? [:]
    }

    func fetchUsage() async throws -> CodexAccountUsage {
        if let activeUsageTask {
            return try await activeUsageTask.value
        }
        let taskID = UUID()
        let resetTask = resetTask
        let task = Task {
            await resetTask?.value
            try Task.checkCancellation()
            return try await provider.usage()
        }
        activeUsageTask = task
        activeUsageTaskID = taskID
        defer {
            if activeUsageTaskID == taskID {
                activeUsageTask = nil
                activeUsageTaskID = nil
            }
        }
        return try await task.value
    }

    func fetchUsage(using credential: Data) async throws -> SavedAccountUsageResult? {
        guard savedAccountUsageTask == nil else { return nil }
        let taskID = UUID()
        let resetTask = resetTask
        let task = Task {
            await resetTask?.value
            try Task.checkCancellation()
            return try await provider.usage(using: credential)
        }
        savedAccountUsageTask = task
        savedAccountUsageTaskID = taskID
        defer {
            if savedAccountUsageTaskID == taskID {
                savedAccountUsageTask = nil
                savedAccountUsageTaskID = nil
            }
        }
        return try await task.value
    }

    func invalidate() {
        activeUsageTask?.cancel()
        activeUsageTask = nil
        activeUsageTaskID = nil
        savedAccountUsageTask?.cancel()
        savedAccountUsageTask = nil
        savedAccountUsageTaskID = nil
        let previousReset = resetTask
        resetTask = Task {
            await previousReset?.value
            await provider.reset()
        }
    }

    func reset() async {
        invalidate()
        await resetTask?.value
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
