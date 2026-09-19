import Foundation

@MainActor
final class DashboardRenderer {
    private struct PendingSynchronization {
        var snapshot: DashboardSnapshot
        var targets: [DevToolsTarget]
        var forceRemount: Bool
        var waiters: [CheckedContinuation<Void, any Error>]
    }

    private let devTools: any DevToolsServing
    private let injectionBundle: InjectionBundle
    private let compatibilityChecker: RendererCompatibilityChecker
    private let promptLibraryBridge: PromptLibraryBridge?
    private var mountedTargetIDs: Set<String> = []
    private var lastSnapshot: DashboardSnapshot?
    private var synchronizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var synchronizationInProgress = false
    private var pendingSynchronization: PendingSynchronization?
    private var lastHealthCheckByTargetID: [String: Date] = [:]
    private var cachedTargets: [DevToolsTarget] = []
    private var lastTargetRefresh: Date?
    private var lastPromptLibrarySynchronization: Date?
    private let healthCheckInterval: TimeInterval
    private let promptLibrarySynchronizationInterval: TimeInterval
    private let now: () -> Date

    private(set) var maintainsDashboard = true

    init(
        devTools: any DevToolsServing = DevToolsClient(),
        injectionBundle: InjectionBundle? = nil,
        promptLibraryStore: PromptLibraryFileStore? = nil,
        healthCheckInterval: TimeInterval = 30,
        promptLibrarySynchronizationInterval: TimeInterval = 10,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.devTools = devTools
        self.injectionBundle = try injectionBundle ?? InjectionBundle.load()
        promptLibraryBridge = promptLibraryStore.map {
            PromptLibraryBridge(devTools: devTools, store: $0)
        }
        self.healthCheckInterval = healthCheckInterval
        self.promptLibrarySynchronizationInterval = promptLibrarySynchronizationInterval
        self.now = now
        compatibilityChecker = RendererCompatibilityChecker(
            devTools: devTools,
            contractSource: try InjectionBundle.loadRendererContractSource()
        )
    }

    func targets(forceRefresh: Bool = false) async -> [DevToolsTarget] {
        if
            !forceRefresh,
            let lastTargetRefresh,
            now().timeIntervalSince(lastTargetRefresh) < healthCheckInterval
        {
            return cachedTargets
        }
        let targets = await devTools.mainRendererTargets()
        cachedTargets = targets
        lastTargetRefresh = now()
        return targets
    }

    func prepareForRestart() {
        maintainsDashboard = true
        clearMountState()
    }

    func synchronize(
        _ snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool = false
    ) async throws {
        if synchronizationInProgress {
            try await withCheckedThrowingContinuation { continuation in
                if var pendingSynchronization {
                    pendingSynchronization.snapshot = snapshot
                    pendingSynchronization.targets = targets
                    pendingSynchronization.forceRemount = pendingSynchronization.forceRemount || forceRemount
                    pendingSynchronization.waiters.append(continuation)
                    self.pendingSynchronization = pendingSynchronization
                } else {
                    pendingSynchronization = PendingSynchronization(
                        snapshot: snapshot,
                        targets: targets,
                        forceRemount: forceRemount,
                        waiters: [continuation]
                    )
                }
            }
            return
        }

        synchronizationInProgress = true
        defer {
            synchronizationInProgress = false
            synchronizationFinished()
        }

        var current = PendingSynchronization(
            snapshot: snapshot,
            targets: targets,
            forceRemount: forceRemount,
            waiters: []
        )
        var initialResult: Result<Void, any Error>?

        while true {
            let result: Result<Void, any Error>
            do {
                try await performSynchronization(
                    current.snapshot,
                    on: current.targets,
                    forceRemount: current.forceRemount
                )
                result = .success(())
            } catch {
                invalidateTargetCache()
                result = .failure(error)
            }

            if initialResult == nil {
                initialResult = result
            }
            for waiter in current.waiters {
                switch result {
                case .success:
                    waiter.resume()
                case .failure(let error):
                    waiter.resume(throwing: error)
                }
            }

            guard let pendingSynchronization else { break }
            self.pendingSynchronization = nil
            current = pendingSynchronization
        }

        try initialResult?.get()
    }

    private func performSynchronization(
        _ snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws {
        try Task.checkCancellation()

        let targetIDs = Set(targets.map(\.id))
        let snapshotChanged = snapshot != lastSnapshot || targetIDs != mountedTargetIDs
        var mountedDashboard = false
        var healthyTargets: [DevToolsTarget] = []

        for target in targets {
            try Task.checkCancellation()
            guard maintainsDashboard else { return }
            let canCheckHealth = !forceRemount && mountedTargetIDs.contains(target.id)
            let isHealthy: Bool
            if canCheckHealth && !snapshotChanged && !healthCheckIsDue(for: target.id) {
                isHealthy = true
            } else if canCheckHealth {
                isHealthy = (try? await devTools.evaluateBoolean(
                    injectionBundle.healthCheckExpression,
                    in: target
                )) == true
                lastHealthCheckByTargetID[target.id] = now()
            } else {
                isHealthy = false
            }
            guard !Task.isCancelled, maintainsDashboard else { return }
            if !isHealthy {
                guard try await devTools.evaluateBoolean(injectionBundle.mountExpression, in: target) else {
                    throw DashboardError.enableFailed(
                        "The dashboard injection did not mount in the Codex renderer."
                    )
                }
                guard !Task.isCancelled, maintainsDashboard else { return }
                mountedDashboard = true
                lastHealthCheckByTargetID[target.id] = now()
            } else {
                healthyTargets.append(target)
            }
        }

        guard !Task.isCancelled, maintainsDashboard else { return }
        if mountedDashboard || promptLibrarySynchronizationIsDue() {
            try await promptLibraryBridge?.synchronize(
                targets: targets,
                healthyTargets: healthyTargets,
                mountedDashboard: mountedDashboard
            )
            lastPromptLibrarySynchronization = now()
        }
        let threadsChanged = snapshot.threads != lastSnapshot?.threads
        let accountPopoverChanged = snapshot.accountPopover != lastSnapshot?.accountPopover
        if mountedDashboard || threadsChanged {
            try await deliverThreads(snapshot.threads, to: targets)
        }
        if mountedDashboard || accountPopoverChanged {
            try await deliverAccountPopover(snapshot.accountPopover, to: targets)
        }
        if mountedDashboard || snapshotChanged {
            guard !Task.isCancelled, maintainsDashboard else { return }
            lastSnapshot = snapshot
        }
        mountedTargetIDs = targetIDs
        lastHealthCheckByTargetID = lastHealthCheckByTargetID.filter { targetIDs.contains($0.key) }
    }

    func disable() async throws -> Bool {
        let wasMaintainingDashboard = maintainsDashboard
        maintainsDashboard = false
        await waitForSynchronizationsToFinish()

        do {
            let targets = await targets(forceRefresh: true)
            guard !targets.isEmpty else {
                clearMountState()
                return false
            }

            for target in targets {
                let disabled = try await devTools.evaluateBoolean(RendererScript.destroy, in: target)
                guard disabled else {
                    throw DashboardError.disableFailed("The renderer still reports an active dashboard.")
                }
            }
            clearMountState()
            return true
        } catch {
            maintainsDashboard = wasMaintainingDashboard
            throw error
        }
    }

    func open() async {
        for target in await targets(forceRefresh: true) {
            _ = try? await devTools.evaluateBoolean(RendererScript.open, in: target)
        }
    }

    func openThread(_ threadID: String) async {
        guard let expression = RendererScript.openThread(threadID) else { return }
        for target in await targets(forceRefresh: true) {
            _ = try? await devTools.evaluateBoolean(expression, in: target)
        }
    }

    func waitForAccountPopoverAction() async -> AccountPopoverActionWaitResult {
        guard let target = (await targets()).first else { return .unavailable }
        do {
            guard let serialized = try await devTools.evaluateString(
                RendererScript.takeNextAccountPopoverAction,
                in: target
            ) else { return .unavailable }
            if serialized == RendererScript.accountPopoverUnavailable { return .unavailable }
            if serialized == "null" { return .timedOut }
            guard let data = serialized.data(using: .utf8),
                  let action = try? JSONDecoder().decode(AccountPopoverAction.self, from: data)
            else { return .unavailable }
            return .action(action)
        } catch {
            return .unavailable
        }
    }

    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async {
        let targets = await targets()
        guard !targets.isEmpty else { return }
        try? await deliverAccountPopover(snapshot, to: targets)
    }

    func preferNativePromptLibraryOnNextSynchronization() {
        promptLibraryBridge?.preferNativeLibrary()
        lastPromptLibrarySynchronization = nil
    }

    func compatibilityChecks() async -> [CompatibilityCheck] {
        await compatibilityChecker.check()
    }

    private func deliverThreads(
        _ threads: [RendererThread],
        to targets: [DevToolsTarget]
    ) async throws {
        try await deliver(RendererScript.deliverThreads(threads), to: targets)
    }

    private func deliverAccountPopover(
        _ snapshot: AccountPopoverSnapshot?,
        to targets: [DevToolsTarget]
    ) async throws {
        try await deliver(RendererScript.deliverAccountPopover(snapshot), to: targets)
    }

    private func deliver(_ expression: String, to targets: [DevToolsTarget]) async throws {
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.enableFailed(
                    "The dashboard was unavailable while thread data was being delivered."
                )
            }
        }
    }

    private func clearMountState() {
        mountedTargetIDs = []
        lastSnapshot = nil
        promptLibraryBridge?.reset()
        lastPromptLibrarySynchronization = nil
        lastHealthCheckByTargetID = [:]
        invalidateTargetCache()
    }

    private func invalidateTargetCache() {
        cachedTargets = []
        lastTargetRefresh = nil
    }

    private func healthCheckIsDue(for targetID: String) -> Bool {
        guard let lastHealthCheck = lastHealthCheckByTargetID[targetID] else { return true }
        return now().timeIntervalSince(lastHealthCheck) >= healthCheckInterval
    }

    private func promptLibrarySynchronizationIsDue() -> Bool {
        guard let lastPromptLibrarySynchronization else { return true }
        return now().timeIntervalSince(lastPromptLibrarySynchronization)
            >= promptLibrarySynchronizationInterval
    }

    private func synchronizationFinished() {
        let waiters = synchronizationWaiters
        synchronizationWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func waitForSynchronizationsToFinish() async {
        guard synchronizationInProgress else { return }
        await withCheckedContinuation { continuation in
            synchronizationWaiters.append(continuation)
        }
    }
}
