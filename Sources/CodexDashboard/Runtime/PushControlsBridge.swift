import Foundation

/// Checks only the repository selected in an open local commit dialog. No fetch,
/// remote access, commits, or pushes are performed by this integration.
@MainActor
struct PushControlsBridge {
    static let checkID = "disable-push-without-remote"
    private struct Inspection: Decodable {
        let state: String
        let requestID: Int
        let path: String?
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
                if inspection.state == "incompatible" {
                    checks.append(Self.check(status: .warning, detail:
                        "Push controls changed in Codex; automatic disabling is unavailable."))
                    continue
                }
                guard inspection.state == "compatible" else { continue }
                if let path = inspection.path, path.hasPrefix("/") {
                    let remote = await Self.hasRemote(at: path)
                    let value = remote.map { $0 ? "true" : "false" } ?? "null"
                    let applied = try await devTools.evaluateBoolean(
                        "window.__codexDashboard?.applyPushRemote?.(\(inspection.requestID), \(value)) === true",
                        in: target
                    )
                    guard applied else { continue } // Closed dialog or changed repository.
                    if remote == nil {
                        checks.append(Self.check(status: .warning, detail:
                            "Git remotes could not be checked; automatic disabling is unavailable for the selected repository."))
                        continue
                    }
                }
                checks.append(Self.check(status: .compatible, detail:
                    "Commit controls are supported. Push actions are disabled when the selected local repository has no remote."))
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

    static func hasRemote(at path: String) async -> Bool? {
        do {
            let repository = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["--no-optional-locks", "-C", path, "rev-parse", "--is-inside-work-tree"],
                timeout: 2
            )
            guard repository.terminationStatus == 0,
                  String(decoding: repository.standardOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
            let remotes = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["--no-optional-locks", "-C", path, "remote"], timeout: 2
            )
            guard remotes.terminationStatus == 0 else { return nil }
            return !String(decoding: remotes.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return nil
        }
    }
}
