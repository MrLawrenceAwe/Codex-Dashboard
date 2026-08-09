import Foundation

@MainActor
struct RendererCompatibilityChecker {
    private let devTools: any DevToolsServing

    init(devTools: any DevToolsServing) {
        self.devTools = devTools
    }

    func check() async -> [CompatibilityCheck] {
        guard let target = await devTools.mainRendererTargets().first else {
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
}
