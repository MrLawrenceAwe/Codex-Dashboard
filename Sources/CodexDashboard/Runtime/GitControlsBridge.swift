import Foundation

/// Publishes Git controls observations from the mounted Dashboard renderers.
@MainActor
struct GitControlsBridge {
    static let toolbarID = "git-toolbar"
    static let pushControlsID = "disable-push-without-remote"
    static let checkIDs: Set<String> = [toolbarID, pushControlsID]

    private struct Inspection: Decodable {
        struct PushControls: Decodable {
            let state: String
        }

        let toolbar: String?
        let pushControls: PushControls?
    }

    let devTools: any DevToolsServing

    func synchronize(in targets: [DevToolsTarget]) async -> [CompatibilityCheck] {
        var toolbarChecks: [CompatibilityCheck] = []
        var pushChecks: [CompatibilityCheck] = []
        for target in targets {
            do {
                let value = try await devTools.evaluateString(
                    """
                    JSON.stringify({
                      toolbar: window.__codexDashboard?.readGitToolbar?.(),
                      pushControls: window.__codexDashboard?.readPushControls?.()
                    })
                    """,
                    in: target, timeout: .seconds(1)
                )
                guard let data = value?.data(using: .utf8),
                      let inspection = try? JSONDecoder().decode(Inspection.self, from: data)
                else { continue }
                toolbarChecks.append(Self.toolbarCheck(for: inspection.toolbar))
                pushChecks.append(Self.pushCheck(for: inspection.pushControls?.state))
            } catch {
                let detail = "The renderer checks could not complete: \(error.localizedDescription)"
                toolbarChecks.append(Self.toolbarCheck(status: .unavailable, detail: detail))
                pushChecks.append(Self.pushCheck(status: .unavailable, detail: detail))
            }
        }

        // A warning in one window takes precedence over a healthy second window.
        return [
            Self.preferred(toolbarChecks) ?? Self.toolbarCheck(for: nil),
            Self.preferred(pushChecks) ?? Self.pushCheck(for: nil),
        ]
    }

    private static func preferred(_ checks: [CompatibilityCheck]) -> CompatibilityCheck? {
        checks.first { $0.status == .warning } ?? checks.first { $0.status == .unavailable }
            ?? checks.first { $0.status == .compatible } ?? checks.first
    }

    private static func toolbarCheck(for state: String?) -> CompatibilityCheck {
        switch state {
        case "missing":
            toolbarCheck(status: .warning, detail:
                "Git toolbar actions are missing in a local project Git chat. Codex Dashboard could not display Commit, Commit & push, and Push.")
        case "compatible":
            toolbarCheck(status: .compatible, detail: "All three Git shortcuts are visible in the local project Git chat.")
        default:
            toolbarCheck(status: .pending, detail: "Open a local project Git chat to check the toolbar shortcuts.")
        }
    }

    private static func pushCheck(for state: String?) -> CompatibilityCheck {
        switch state {
        case "incompatible":
            pushCheck(status: .warning, detail: "Push controls changed in Codex; automatic disabling is unavailable.")
        case "remote-unavailable":
            pushCheck(status: .warning, detail:
                "Git remotes could not be checked through Codex; automatic disabling is unavailable for the selected repository.")
        case "compatible":
            pushCheck(status: .compatible, detail:
                "Commit controls are supported. Push actions are disabled when the selected local repository has no remote.")
        default:
            pushCheck(status: .pending, detail: "Open Commit or push in a local repository to check these controls.")
        }
    }

    private static func toolbarCheck(status: CompatibilityStatus, detail: String) -> CompatibilityCheck {
        CompatibilityCheck(id: toolbarID, title: "Git toolbar actions", status: status, detail: detail)
    }

    static func pushCheck(status: CompatibilityStatus, detail: String) -> CompatibilityCheck {
        CompatibilityCheck(id: pushControlsID, title: "Disable push without a remote", status: status, detail: detail)
    }
}
