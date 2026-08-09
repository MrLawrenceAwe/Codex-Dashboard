import Foundation

@MainActor
final class DashboardRenderer {
    private let devTools: any DevToolsServing
    private let injection: DashboardInjection
    private var mountedTargetIDs: Set<String> = []
    private var lastSnapshot: RendererSnapshot?

    private(set) var maintainsDashboard = true

    init(
        devTools: any DevToolsServing = DevToolsClient(),
        injection: DashboardInjection? = nil
    ) throws {
        self.devTools = devTools
        self.injection = try injection ?? DashboardInjection.load()
    }

    func targets() async -> [DevToolsTarget] {
        await devTools.mainRendererTargets()
    }

    func prepareForRestart() {
        maintainsDashboard = true
        clearMountState()
    }

    func stopMaintaining() {
        maintainsDashboard = false
        clearMountState()
    }

    func synchronize(
        _ snapshot: RendererSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool = false
    ) async throws {
        let targetIDs = Set(targets.map(\.id))
        var mountedDashboard = false

        for target in targets {
            try Task.checkCancellation()
            guard maintainsDashboard else { return }
            let canCheckHealth = !forceRemount && mountedTargetIDs.contains(target.id)
            let isHealthy: Bool
            if canCheckHealth {
                isHealthy = (try? await devTools.evaluateBoolean(
                    injection.healthCheckExpression,
                    in: target
                )) == true
            } else {
                isHealthy = false
            }
            guard !Task.isCancelled, maintainsDashboard else { return }
            if !isHealthy {
                guard try await devTools.evaluateBoolean(injection.mountExpression, in: target) else {
                    throw DashboardError.enableFailed(
                        "The dashboard injection did not mount in the Codex renderer."
                    )
                }
                mountedDashboard = true
            }
        }

        if mountedDashboard || snapshot != lastSnapshot || targetIDs != mountedTargetIDs {
            try await deliver(snapshot, to: targets)
            lastSnapshot = snapshot
        }
        mountedTargetIDs = targetIDs
    }

    func disable() async throws -> Bool {
        let targets = await targets()
        guard !targets.isEmpty else {
            stopMaintaining()
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
        stopMaintaining()
        return true
    }

    func open() async {
        for target in await targets() {
            _ = try? await devTools.evaluateBoolean(
                "(() => { window.__codexDashboard?.open?.(); return true; })()",
                in: target
            )
        }
    }

    private func deliver(_ snapshot: RendererSnapshot, to targets: [DevToolsTarget]) async throws {
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
    }
}
