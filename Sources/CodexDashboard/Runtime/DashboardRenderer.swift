import Foundation

@MainActor
final class DashboardRenderer {
    private let devTools: any DevToolsServing
    private let injectionPayload: DashboardInjectionPayload
    private let compatibilityChecker: RendererCompatibilityChecker
    private let promptBackupStore: PromptBackupStore?
    private var mountedTargetIDs: Set<String> = []
    private var lastSnapshot: DashboardSnapshot?
    private var activeSynchronizationCount = 0
    private var synchronizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var synchronizationInProgress = false
    private var queuedSynchronizations: [CheckedContinuation<Void, Never>] = []
    private var lastPromptBackupCheck: Date?

    private static let promptBackupCheckInterval: TimeInterval = 30

    private(set) var maintainsDashboard = true

    init(
        devTools: any DevToolsServing = DevToolsClient(),
        injectionPayload: DashboardInjectionPayload? = nil,
        promptBackupStore: PromptBackupStore? = nil
    ) throws {
        self.devTools = devTools
        self.injectionPayload = try injectionPayload ?? DashboardInjectionPayload.load()
        self.promptBackupStore = promptBackupStore
        compatibilityChecker = RendererCompatibilityChecker(
            devTools: devTools,
            contractSource: try DashboardInjectionPayload.loadRendererContractSource()
        )
    }

    func targets() async -> [DevToolsTarget] {
        await devTools.mainRendererTargets()
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
        activeSynchronizationCount += 1
        defer { synchronizationFinished() }
        await acquireSynchronizationSlot()
        defer { releaseSynchronizationSlot() }
        try Task.checkCancellation()

        let targetIDs = Set(targets.map(\.id))
        var mountedDashboard = false

        for target in targets {
            try Task.checkCancellation()
            guard maintainsDashboard else { return }
            let canCheckHealth = !forceRemount && mountedTargetIDs.contains(target.id)
            let isHealthy: Bool
            if canCheckHealth {
                isHealthy = (try? await devTools.evaluateBoolean(
                    injectionPayload.healthCheckExpression,
                    in: target
                )) == true
            } else {
                isHealthy = false
            }
            guard !Task.isCancelled, maintainsDashboard else { return }
            if !isHealthy {
                await restorePromptBackupIfNeeded(in: target)
                guard try await devTools.evaluateBoolean(injectionPayload.mountExpression, in: target) else {
                    throw DashboardError.enableFailed(
                        "The dashboard injection did not mount in the Codex renderer."
                    )
                }
                guard !Task.isCancelled, maintainsDashboard else { return }
                mountedDashboard = true
            }
        }

        guard !Task.isCancelled, maintainsDashboard else { return }
        if mountedDashboard || snapshot != lastSnapshot || targetIDs != mountedTargetIDs {
            try await deliver(snapshot, to: targets)
            guard !Task.isCancelled, maintainsDashboard else { return }
            lastSnapshot = snapshot
        }
        mountedTargetIDs = targetIDs
        if shouldBackUpPromptLibrary(afterMounting: mountedDashboard) {
            await backUpPromptLibrary(from: targets.first)
        }
    }

    func disable() async throws -> Bool {
        let wasMaintainingDashboard = maintainsDashboard
        maintainsDashboard = false
        await waitForSynchronizationsToFinish()

        do {
            let targets = await targets()
            guard !targets.isEmpty else {
                clearMountState()
                return false
            }

            for target in targets {
                let disabled = try await devTools.evaluateBoolean(
                    "(() => { window.__codexDashboard?.destroy?.(); return typeof window.__codexDashboard === 'undefined'; })()",
                    in: target
                )
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
        for target in await targets() {
            _ = try? await devTools.evaluateBoolean(
                "(() => { window.__codexDashboard?.open?.(); return true; })()",
                in: target
            )
        }
    }

    func compatibilityChecks() async -> [CompatibilityCheck] {
        await compatibilityChecker.check()
    }

    private func deliver(_ snapshot: DashboardSnapshot, to targets: [DevToolsTarget]) async throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DashboardError.enableFailed("Thread data could not be encoded for the renderer.")
        }
        let expression = """
        (() => {
          const dashboard = window.__codexDashboard;
          if (typeof dashboard?.applySnapshot !== 'function') return false;
          dashboard.applySnapshot(\(json));
          return true;
        })()
        """
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
        lastPromptBackupCheck = nil
    }

    private func shouldBackUpPromptLibrary(afterMounting mountedDashboard: Bool) -> Bool {
        let now = Date()
        guard !mountedDashboard, let lastPromptBackupCheck else {
            self.lastPromptBackupCheck = now
            return true
        }
        guard now.timeIntervalSince(lastPromptBackupCheck) >= Self.promptBackupCheckInterval else {
            return false
        }
        self.lastPromptBackupCheck = now
        return true
    }

    private func restorePromptBackupIfNeeded(in target: DevToolsTarget) async {
        guard let promptBackupStore else { return }
        guard let backup = await promptBackupStore.load(),
              let data = try? JSONSerialization.data(withJSONObject: backup, options: .fragmentsAllowed),
              let encodedBackup = String(data: data, encoding: .utf8)
        else { return }
        let expression = """
        (() => {
          const key = 'codex-dashboard.prompt-library';
          if (localStorage.getItem(key)) return true;
          localStorage.setItem(key, \(encodedBackup));
          return true;
        })()
        """
        _ = try? await devTools.evaluateBoolean(expression, in: target)
    }

    private func backUpPromptLibrary(from target: DevToolsTarget?) async {
        guard let promptBackupStore,
              let target,
              let json = try? await devTools.evaluateString(
                "localStorage.getItem('codex-dashboard.prompt-library')",
                in: target
              )
        else { return }
        _ = try? await promptBackupStore.save(json)
    }

    private func synchronizationFinished() {
        activeSynchronizationCount -= 1
        guard activeSynchronizationCount == 0 else { return }
        let waiters = synchronizationWaiters
        synchronizationWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func acquireSynchronizationSlot() async {
        guard synchronizationInProgress else {
            synchronizationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            queuedSynchronizations.append(continuation)
        }
    }

    private func releaseSynchronizationSlot() {
        guard !queuedSynchronizations.isEmpty else {
            synchronizationInProgress = false
            return
        }
        queuedSynchronizations.removeFirst().resume()
    }

    private func waitForSynchronizationsToFinish() async {
        guard activeSynchronizationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            synchronizationWaiters.append(continuation)
        }
    }
}
