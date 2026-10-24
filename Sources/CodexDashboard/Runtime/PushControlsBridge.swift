import Foundation

/// Publishes runtime compatibility observations. The renderer reads local Git
/// metadata directly through Codex's worker bridge when the commit dialog opens.
@MainActor
struct PushControlsBridge {
    static let checkID = "disable-push-without-remote"
    private struct Inspection: Decodable {
        let state: String
    }

    let devTools: any DevToolsServing

    func synchronize(in targets: [DevToolsTarget]) async -> CompatibilityCheck? {
        var checks: [CompatibilityCheck] = []
        for target in targets {
            do {
                guard let value = try await devTools.evaluateString(
                    "JSON.stringify(window.__codexDashboard?.readPushControls?.() ?? null)",
                    in: target, timeout: .seconds(1)
                ), let data = value.data(using: .utf8),
                    let inspection = try? JSONDecoder().decode(Inspection.self, from: data)
                else { continue }
                switch inspection.state {
                case "incompatible":
                    checks.append(Self.check(status: .warning, detail:
                        "Push controls changed in Codex; automatic disabling is unavailable."))
                case "remote-unavailable":
                    checks.append(Self.check(status: .warning, detail:
                        "Git remotes could not be checked through Codex; automatic disabling is unavailable for the selected repository."))
                case "compatible":
                    checks.append(Self.check(status: .compatible, detail:
                        "Commit controls are supported. Push actions are disabled when the selected local repository has no remote."))
                default: break
                }
            } catch {
                checks.append(Self.check(status: .unavailable, detail:
                    "Push controls could not be inspected: \(error.localizedDescription)"))
            }
        }
        // An incompatible window must not be hidden by a compatible second window.
        return checks.first { $0.status != .compatible } ?? checks.first
    }

    static func check(status: CompatibilityStatus, detail: String) -> CompatibilityCheck {
        CompatibilityCheck(id: checkID, title: "Disable push without a remote", status: status, detail: detail)
    }
}
