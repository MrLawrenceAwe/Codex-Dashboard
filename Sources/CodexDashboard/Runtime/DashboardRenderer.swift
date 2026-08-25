import Foundation

@MainActor
final class DashboardRenderer {
    private struct PendingSynchronization {
        var snapshot: DashboardSnapshotPayload
        var targets: [DevToolsTarget]
        var forceRemount: Bool
        var waiters: [CheckedContinuation<Void, any Error>]
    }

    private let devTools: any DevToolsServing
    private let injectionPayload: DashboardInjectionResources
    private let compatibilityChecker: RendererCompatibilityChecker
    private let promptLibraryStore: PromptLibraryFileStore?
    private var mountedTargetIDs: Set<String> = []
    private var lastSnapshot: DashboardSnapshotPayload?
    private var lastDeliveredPromptLibrary: PromptLibraryDocument?
    private var synchronizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var synchronizationInProgress = false
    private var pendingSynchronization: PendingSynchronization?
    private var lastHealthCheckByTargetID: [String: Date] = [:]
    private var cachedTargets: [DevToolsTarget] = []
    private var lastTargetRefresh: Date?
    private let healthCheckInterval: TimeInterval
    private let now: () -> Date

    private(set) var maintainsDashboard = true

    init(
        devTools: any DevToolsServing = DevToolsClient(),
        injectionPayload: DashboardInjectionResources? = nil,
        promptLibraryStore: PromptLibraryFileStore? = nil,
        healthCheckInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.devTools = devTools
        self.injectionPayload = try injectionPayload ?? DashboardInjectionResources.load()
        self.promptLibraryStore = promptLibraryStore
        self.healthCheckInterval = healthCheckInterval
        self.now = now
        compatibilityChecker = RendererCompatibilityChecker(
            devTools: devTools,
            contractSource: try DashboardInjectionResources.loadRendererContractSource()
        )
    }

    func targets(forceRefresh: Bool = false) async -> [DevToolsTarget] {
        if
            !forceRefresh,
            !cachedTargets.isEmpty,
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
        _ snapshot: DashboardSnapshotPayload,
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
        _ snapshot: DashboardSnapshotPayload,
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
                    injectionPayload.healthCheckExpression,
                    in: target
                )) == true
                lastHealthCheckByTargetID[target.id] = now()
            } else {
                isHealthy = false
            }
            guard !Task.isCancelled, maintainsDashboard else { return }
            if !isHealthy {
                guard try await devTools.evaluateBoolean(injectionPayload.mountExpression, in: target) else {
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
        try await synchronizePromptLibrary(
            on: targets,
            healthyTargets: healthyTargets,
            mountedDashboard: mountedDashboard
        )
        if mountedDashboard || snapshotChanged {
            try await deliver(snapshot, to: targets)
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
                let disabled = try await devTools.evaluateBoolean(DashboardRendererScript.destroy, in: target)
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
            _ = try? await devTools.evaluateBoolean(DashboardRendererScript.open, in: target)
        }
    }

    func openThread(_ threadID: String) async {
        guard let expression = DashboardRendererScript.openThread(threadID) else { return }
        for target in await targets(forceRefresh: true) {
            _ = try? await devTools.evaluateBoolean(expression, in: target)
        }
    }

    func consumeAccountAction() async -> DashboardAccountAction? {
        for target in await targets(forceRefresh: false) {
            guard
                let serialized = try? await devTools.evaluateString(
                    DashboardRendererScript.consumeAccountAction,
                    in: target
                ),
                let data = serialized.data(using: .utf8),
                let action = try? JSONDecoder().decode(DashboardAccountAction.self, from: data)
            else { continue }
            return action
        }
        return nil
    }

    func compatibilityChecks() async -> [CompatibilityCheck] {
        await compatibilityChecker.check()
    }

    private func deliver(_ snapshot: DashboardSnapshotPayload, to targets: [DevToolsTarget]) async throws {
        let expression = try DashboardRendererScript.deliver(snapshot)
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.enableFailed(
                    "The dashboard was unavailable while thread data was being delivered."
                )
            }
        }
    }

    private func synchronizePromptLibrary(
        on targets: [DevToolsTarget],
        healthyTargets: [DevToolsTarget],
        mountedDashboard: Bool
    ) async throws {
        guard let promptLibraryStore, let firstTarget = targets.first else { return }
        let storedBeforeSynchronization = try promptLibraryStore.load()
        let nativeLibraryChanged = storedBeforeSynchronization != lastDeliveredPromptLibrary
        let sourceTarget = healthyTargets.first ?? (storedBeforeSynchronization == nil ? firstTarget : nil)

        if !nativeLibraryChanged, let sourceTarget,
           let serialized = try await devTools.evaluateString(
               DashboardRendererScript.exportPromptLibrary,
               in: sourceTarget
           ),
           let data = serialized.data(using: .utf8),
           let rendererLibrary = try? JSONDecoder().decode(PromptLibraryDocument.self, from: data),
           rendererLibrary.isValid
        {
            _ = try promptLibraryStore.save(rendererLibrary)
        }

        guard let nativeLibrary = try promptLibraryStore.load() else { return }
        guard mountedDashboard || nativeLibrary != lastDeliveredPromptLibrary else { return }
        let expression = try DashboardRendererScript.deliverPromptLibrary(nativeLibrary)
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.enableFailed("The prompt library was unavailable in the Codex renderer.")
            }
        }
        lastDeliveredPromptLibrary = nativeLibrary
    }

    private func clearMountState() {
        mountedTargetIDs = []
        lastSnapshot = nil
        lastDeliveredPromptLibrary = nil
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
