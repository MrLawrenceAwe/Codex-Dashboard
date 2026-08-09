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

    func compatibilityChecks() async -> [CompatibilityCheck] {
        guard let target = await targets().first else {
            return [CompatibilityCheck(
                id: "renderer",
                title: "Renderer connection",
                status: .unavailable,
                detail: "Restart Codex through this controller to inspect renderer contracts."
            )]
        }

        var checks = [CompatibilityCheck(
            id: "renderer",
            title: "Renderer connection",
            status: .compatible,
            detail: "The main Codex renderer is available through local DevTools."
        )]
        checks.append(await inspect(
            id: "sidebar-host",
            title: "Sidebar integration",
            expression: "Boolean(document.querySelector('aside.app-shell-left-panel, aside') && document.querySelector('nav, [role=\"navigation\"]'))",
            failureStatus: .incompatible,
            compatibleDetail: "The dashboard sidebar host and navigation container are available.",
            failureDetail: "The expected sidebar or navigation container was not found.",
            in: target
        ))
        checks.append(await inspect(
            id: "thread-navigation",
            title: "Thread navigation",
            expression: "Boolean(document.querySelector('[data-app-action-sidebar-thread-id]'))",
            failureStatus: .warning,
            compatibleDetail: "Codex exposes sidebar thread actions used for direct navigation.",
            failureDetail: "No sidebar thread action is currently mounted; route fallback remains available.",
            in: target
        ))
        checks.append(await inspect(
            id: "sidebar-unread",
            title: "Sidebar unread sync",
            expression: """
            (() => [...document.querySelectorAll('[data-app-action-sidebar-thread-id]')].some((row) => {
              const key = Object.keys(row).find((candidate) => candidate.startsWith('__reactFiber$'));
              let fiber = key ? row[key] : null;
              while (fiber) {
                const props = fiber.memoizedProps || fiber.pendingProps;
                if (typeof props?.conversationId === 'string' && typeof props?.isUnread === 'boolean') return true;
                fiber = fiber.return;
              }
              return false;
            }))()
            """,
            failureStatus: .warning,
            compatibleDetail: "Codex's mounted thread rows expose the unread state used for immediate synchronization.",
            failureDetail: "The React unread-state contract was not found; persisted unread state remains available.",
            in: target
        ))
        checks.append(await inspect(
            id: "composer",
            title: "Composer integration",
            expression: "[...document.querySelectorAll('textarea, [contenteditable=\"true\"][role=\"textbox\"], [contenteditable=\"true\"]')].some((element) => !element.closest('#codex-dashboard-prompt-dialog') && element.getClientRects().length > 0)",
            failureStatus: .warning,
            compatibleDetail: "A supported Codex composer is available for saved-prompt insertion.",
            failureDetail: "No supported composer is currently mounted.",
            in: target
        ))

        let promptMenuIsOpen = (try? await devTools.evaluateBoolean(
            "[...document.querySelectorAll('[data-composer-overlay-floating-ui], [role=\"menu\"], [data-radix-menu-content], [data-slot=\"dropdown-menu-content\"]')].some((menu) => menu.textContent.includes('Work in a project') && menu.textContent.includes('Plan mode'))",
            in: target
        )) == true
        if promptMenuIsOpen {
            checks.append(await inspect(
                id: "prompt-menu",
                title: "Prompt menu anchor",
                expression: "[...document.querySelectorAll('button, [role=\"menuitem\"], span, div')].some((element) => element.textContent?.trim() === 'Record a skill')",
                failureStatus: .incompatible,
                compatibleDetail: "The Record a skill anchor used by the Prompts item is available.",
                failureDetail: "The open Add menu no longer contains the expected Record a skill anchor.",
                in: target
            ))
        } else {
            checks.append(CompatibilityCheck(
                id: "prompt-menu",
                title: "Prompt menu anchor",
                status: .unavailable,
                detail: "Open the composer Add menu and run the check again to verify this anchor."
            ))
        }
        return checks
    }

    private func inspect(
        id: String,
        title: String,
        expression: String,
        failureStatus: CompatibilityStatus,
        compatibleDetail: String,
        failureDetail: String,
        in target: DevToolsTarget
    ) async -> CompatibilityCheck {
        do {
            let matches = try await devTools.evaluateBoolean(expression, in: target)
            return CompatibilityCheck(
                id: id,
                title: title,
                status: matches ? .compatible : failureStatus,
                detail: matches ? compatibleDetail : failureDetail
            )
        } catch {
            return CompatibilityCheck(
                id: id,
                title: title,
                status: .unavailable,
                detail: "The renderer check could not complete: \(error.localizedDescription)"
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
