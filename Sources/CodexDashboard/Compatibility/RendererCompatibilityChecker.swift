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
                detail: "Restart Codex from the Codex Dashboard menu to inspect renderer contracts."
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
                "Boolean(codexUIContracts.sidebar() && codexUIContracts.navigation())"
            ),
            failureStatus: .incompatible,
            compatibleDetail: "The dashboard sidebar host and navigation container are available.",
            failureDetail: "The expected sidebar or navigation container was not found.",
            in: target
        ))
        checks.append(await inspect(
            id: "thread-navigation",
            title: "Thread navigation",
            expression: contractExpression("codexUIContracts.threadRows().length > 0"),
            failureStatus: .warning,
            compatibleDetail: "Codex exposes sidebar thread actions used for direct navigation.",
            failureDetail: "No sidebar thread action is currently mounted; route fallback remains available.",
            in: target
        ))
        checks.append(await inspect(
            id: "sidebar-unread",
            title: "Sidebar unread sync",
            expression: contractExpression("codexUIContracts.threadReadStates().size > 0"),
            failureStatus: .warning,
            compatibleDetail: "Codex's mounted thread rows expose the unread state used for immediate synchronization.",
            failureDetail: "The React unread-state contract was not found; persisted unread state remains available.",
            in: target
        ))
        checks.append(await inspect(
            id: "composer",
            title: "Composer integration",
            expression: contractExpression(
                "(() => { const composer = codexUIContracts.composer(); return Boolean(composer && (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement || codexUIContracts.composerEditorView(composer))); })()"
            ),
            failureStatus: .warning,
            compatibleDetail: "A supported Codex composer and insertion contract are available for saved prompts.",
            failureDetail: "No supported composer insertion contract is currently mounted.",
            in: target
        ))

        checks.append(await inspect(
            id: "composer-controls",
            title: "Composer controls",
            expression: contractExpression(
                "Boolean(codexUIContracts.composerAddButton())"
            ),
            failureStatus: .warning,
            compatibleDetail: "Codex exposes an Add button beside the active composer for prompt-library integration.",
            failureDetail: "No compatible composer Add button is currently mounted.",
            in: target
        ))
        checks.append(await inspect(
            id: "profile-menu",
            title: "Account menu integration",
            expression: contractExpression(
                "Boolean(codexUIContracts.profileMenuTrigger())"
            ),
            failureStatus: .warning,
            compatibleDetail: "Codex exposes the profile-menu entry point used for account integration.",
            failureDetail: "The compatible profile-menu entry point was not found.",
            in: target
        ))
        checks.append(await inspect(
            id: "model-picker",
            title: "Model preset controls",
            expression: contractExpression(
                "codexUIContracts.probeModelPickerControls()"
            ),
            failureStatus: .warning,
            compatibleDetail: "Codex exposes the model-picker and reasoning controls used by saved prompt presets.",
            failureDetail: "The model-picker or reasoning controls used by saved prompt presets were not found.",
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
