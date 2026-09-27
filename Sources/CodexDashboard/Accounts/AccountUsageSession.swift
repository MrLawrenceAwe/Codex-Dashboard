import Foundation

@MainActor
final class AccountUsageSession {
    private struct InFlightRequest<Value: Sendable> {
        let token: UUID
        let task: Task<Value, Error>
    }

    private let provider: any AccountUsageProviding
    private let cache: any UsageCaching
    private var activeRequest: InFlightRequest<CodexAccountUsage>?
    private var savedAccountRequests: [UUID: InFlightRequest<SavedAccountUsageResult>] = [:]
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
        if let activeRequest {
            return try await activeRequest.task.value
        }
        let taskID = UUID()
        let resetTask = resetTask
        let task = Task {
            await resetTask?.value
            try Task.checkCancellation()
            return try await provider.usage()
        }
        activeRequest = InFlightRequest(token: taskID, task: task)
        defer {
            if activeRequest?.token == taskID { activeRequest = nil }
        }
        return try await task.value
    }

    func fetchUsage(
        using credential: Data,
        for accountID: UUID
    ) async throws -> SavedAccountUsageResult {
        if let request = savedAccountRequests[accountID] {
            return try await request.task.value
        }
        let taskID = UUID()
        let resetTask = resetTask
        let task = Task {
            await resetTask?.value
            try Task.checkCancellation()
            return try await provider.usage(using: credential)
        }
        savedAccountRequests[accountID] = InFlightRequest(token: taskID, task: task)
        defer {
            if savedAccountRequests[accountID]?.token == taskID { savedAccountRequests[accountID] = nil }
        }
        return try await task.value
    }

    func invalidate() {
        activeRequest?.task.cancel()
        activeRequest = nil
        savedAccountRequests.values.forEach { $0.task.cancel() }
        savedAccountRequests = [:]
        let previousReset = resetTask
        resetTask = Task {
            await previousReset?.value
            await provider.reset()
        }
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
