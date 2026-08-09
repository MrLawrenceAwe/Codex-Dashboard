import Foundation

@MainActor
struct RendererCompatibilityChecker {
    private let devTools: any DevToolsServing
    private let contractSource: String

    init(devTools: any DevToolsServing, contractSource: String) {
        self.devTools = devTools
        self.contractSource = contractSource
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
            expression: contractExpression(
                "Boolean(codexContracts.sidebar() && codexContracts.navigation())"
            ),
            failureStatus: .incompatible,
            compatibleDetail: "The dashboard sidebar host and navigation container are available.",
            failureDetail: "The expected sidebar or navigation container was not found.",
            in: target
        ))
        checks.append(await inspect(
            id: "thread-navigation",
            title: "Thread navigation",
            expression: contractExpression("codexContracts.threadRows().length > 0"),
            failureStatus: .warning,
            compatibleDetail: "Codex exposes sidebar thread actions used for direct navigation.",
            failureDetail: "No sidebar thread action is currently mounted; route fallback remains available.",
            in: target
        ))
        checks.append(await inspect(
            id: "sidebar-unread",
            title: "Sidebar unread sync",
            expression: contractExpression("codexContracts.threadReadStates().size > 0"),
            failureStatus: .warning,
            compatibleDetail: "Codex's mounted thread rows expose the unread state used for immediate synchronization.",
            failureDetail: "The React unread-state contract was not found; persisted unread state remains available.",
            in: target
        ))
        checks.append(await inspect(
            id: "composer",
            title: "Composer integration",
            expression: contractExpression("Boolean(codexContracts.composer())"),
            failureStatus: .warning,
            compatibleDetail: "A supported Codex composer is available for saved-prompt insertion.",
            failureDetail: "No supported composer is currently mounted.",
            in: target
        ))

        checks.append(await inspect(
            id: "composer-controls",
            title: "Composer controls",
            expression: contractExpression(
                "codexContracts.composerAddButton()?.nextElementSibling?.matches('[data-codex-prompt-launcher]') === true"
            ),
            failureStatus: .incompatible,
            compatibleDetail: "The Prompts control is mounted directly beside the composer Add button.",
            failureDetail: "The Prompts control is not mounted beside the composer Add button.",
            in: target
        ))
        return checks
    }

    private func contractExpression(_ expression: String) -> String {
        """
        (() => {
          \(contractSource)
          return \(expression);
        })()
        """
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
