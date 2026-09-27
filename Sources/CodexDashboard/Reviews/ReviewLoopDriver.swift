import Foundation

/// Uses the desktop app's existing local app-server connection. No composer mutation,
/// CLI-owned background session, inherited conversation, or permission override.
@MainActor
final class ReviewLoopDriver: ReviewLoopDriving {
    private let devTools: any DevToolsServing
    private let target: DevToolsTarget
    init(devTools: any DevToolsServing, target: DevToolsTarget) {
        self.devTools = devTools
        self.target = target
    }

    func projects() async throws -> [ReviewProject] {
        var projects: [ReviewProject] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await request("project/list", params)
            guard let rows = response["data"] as? [[String: Any]] else { throw ReviewLoopError("Codex returned an invalid project list.") }
            for row in rows {
                guard let id = row["id"] as? String, let name = row["name"] as? String,
                      let roots = row["roots"] as? [[String: Any]], roots.count == 1,
                      let path = roots.first?["path"] as? String, path.hasPrefix("/") else { continue }
                projects.append(ReviewProject(id: id, name: name, path: path))
            }
            let next = response["nextCursor"] as? String
            guard next == nil || next != cursor else { throw ReviewLoopError("Codex repeated its project cursor.") }
            cursor = next
        } while cursor != nil
        return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func models() async throws -> [ReviewModel] {
        var models: [ReviewModel] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await request("model/list", params)
            guard let rows = response["data"] as? [[String: Any]] else { throw ReviewLoopError("Codex returned an invalid model list.") }
            for row in rows where row["hidden"] as? Bool != true {
                guard let model = row["model"] as? String, let name = row["displayName"] as? String,
                      let efforts = row["supportedReasoningEfforts"] as? [[String: Any]] else { continue }
                models.append(ReviewModel(model: model, displayName: name, efforts: efforts.compactMap { $0["reasoningEffort"] as? String }))
            }
            let next = response["nextCursor"] as? String
            guard next == nil || next != cursor else { throw ReviewLoopError("Codex repeated its model cursor.") }
            cursor = next
        } while cursor != nil
        return models
    }

    func repository(at path: String) async throws -> ReviewRepositoryState {
        let root = try await git(["rev-parse", "--show-toplevel"], at: path)
        let branch = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path)
        let head = try await git(["rev-parse", "HEAD"], at: path)
        let status = try await git(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], at: path)
        // Read HEAD again to reject a checkpoint taken across a concurrent commit.
        guard head == (try await git(["rev-parse", "HEAD"], at: path)) else {
            throw ReviewLoopError("HEAD changed while checking the commit checkpoint.")
        }
        return ReviewRepositoryState(root: root, branch: branch, commit: head, clean: status.isEmpty)
    }

    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        guard (4...64).contains(commit.count),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw ReviewLoopError("Commit checkpoint failed: the fix report must contain a Git commit ID.")
        }
        let result = try await runGit(["rev-parse", "--verify", "--end-of-options", commit.lowercased() + "^{commit}"], at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Commit checkpoint failed: the reported commit ID is missing, ambiguous, or does not identify a commit.")
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool {
        let result = try await runGit(["merge-base", "--is-ancestor", commit, head], at: path)
        guard result.terminationStatus <= 1 else { throw ReviewLoopError("Could not verify the review commit ancestry.") }
        return result.terminationStatus == 0
    }

    func createThread(project: ReviewProject, title: String, speed: ReviewSpeed) async throws -> String {
        let response = try await request("thread/start", [
            "cwd": project.path, "projectId": project.id,
            "serviceTier": speed.serviceTier,
            "experimentalRawEvents": false, "ephemeral": false,
        ])
        guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else {
            throw ReviewLoopError("Codex did not return the new review task ID.")
        }
        // A title is cosmetic; its failure must not turn a known launch into an unknown one.
        _ = try? await request("thread/name/set", ["threadId": id, "name": title])
        return id
    }

    func startTurn(threadID: String, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String {
        var params: [String: Any] = [
            "threadId": threadID,
            "serviceTierForTurn": speed.serviceTier,
            "input": [["type": "text", "text": prompt + "\n\n" + ReviewLoopReport.instructions(for: kind), "text_elements": []]],
        ]
        if let selection {
            params["model"] = selection.model
            if let effort = selection.effort { params["effort"] = effort }
        }
        let response = try await request("turn/start", params)
        guard let turn = response["turn"] as? [String: Any], let id = turn["id"] as? String else {
            throw ReviewLoopError("Codex did not acknowledge the review prompt. It will not be resent automatically.")
        }
        return id
    }

    func readThread(_ threadID: String) async throws -> ReviewThreadState {
        let response = try await request("thread/read", ["threadId": threadID, "includeTurns": false])
        guard var thread = response["thread"] as? [String: Any] else { throw ReviewLoopError("Codex returned no review task.") }
        // Bounded metadata reads avoid hydrating a long tool transcript on every poll.
        let page = try await request("thread/turns/list", ["threadId": threadID, "limit": 3, "sortDirection": "asc", "itemsView": "notLoaded"])
        guard var turns = page["data"] as? [[String: Any]], turns.count <= 2,
              page["nextCursor"] == nil || page["nextCursor"] is NSNull else {
            throw ReviewLoopError("The review chat contains unexpected additional turns.")
        }
        for index in turns.indices where turns[index]["status"] as? String == "completed" {
            guard let turnID = turns[index]["id"] as? String else { throw ReviewLoopError("Missing review turn ID.") }
            var cursor: String?
            for _ in 0..<20 {
                var params: [String: Any] = ["threadId": threadID, "turnId": turnID, "limit": 1, "sortDirection": "desc"]
                if let cursor { params["cursor"] = cursor }
                let items = try await request("thread/items/list", params)
                guard let entries = items["data"] as? [[String: Any]] else { throw ReviewLoopError("Codex returned invalid review items.") }
                if let item = entries.compactMap({ $0["item"] as? [String: Any] }).first(where: {
                    $0["type"] as? String == "agentMessage" && $0["phase"] as? String != "commentary"
                }) {
                    turns[index]["items"] = [item]
                    break
                }
                guard let next = items["nextCursor"] as? String, next != cursor else { break }
                cursor = next
            }
        }
        thread["turns"] = turns
        return try Self.threadState(["thread": thread])
    }

    static func threadState(_ response: [String: Any]) throws -> ReviewThreadState {
        guard let thread = response["thread"] as? [String: Any], let cwd = thread["cwd"] as? String,
              let turns = thread["turns"] as? [[String: Any]], turns.count <= 2 else {
            throw ReviewLoopError("The review chat changed or its history could not be verified.")
        }
        let threadStatus = thread["status"] as? [String: Any]
        let statusType = threadStatus?["type"] as? String
        let activeFlags = threadStatus?["activeFlags"] as? [String] ?? []
        if activeFlags.contains("waitingOnApproval") || activeFlags.contains("waitingOnUserInput") {
            throw ReviewLoopError("The review task needs your approval or input. Open its chat; the loop will not continue automatically.")
        }
        let states = try turns.map { turn -> ReviewTurnState in
            guard let id = turn["id"] as? String, let status = turn["status"] as? String else {
                throw ReviewLoopError("Codex returned an invalid review turn.")
            }
            if status == "inProgress", statusType != "active" {
                throw ReviewLoopError("The review task is no longer active. Open its chat before restarting the loop.")
            }
            let items = turn["items"] as? [[String: Any]] ?? []
            let final = items.last { $0["type"] as? String == "agentMessage" && $0["phase"] as? String != "commentary" }
            return ReviewTurnState(id: id, status: status, finalMessage: final?["text"] as? String)
        }
        return ReviewThreadState(cwd: cwd, turns: states)
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params], options: [.sortedKeys])
        let argument = String(decoding: data, as: UTF8.self)
        let expression = "window.__codexDashboard.reviewRequest(\(argument))"
        guard let text = try await devTools.evaluateString(expression, in: target, timeout: .seconds(25)),
              let data = text.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReviewLoopError("The Codex review connection returned an unreadable response.")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw ReviewLoopError(error["message"] as? String ?? "Codex rejected the review request.")
        }
        guard let result = envelope["result"] as? [String: Any] else { throw ReviewLoopError("Codex returned no review result.") }
        return result
    }

    private func git(_ arguments: [String], at path: String) async throws -> String {
        let result = try await runGit(arguments, at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Git checkpoint failed: " + String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ arguments: [String], at path: String) async throws -> SubprocessOutput {
        try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--no-optional-locks", "-C", path] + arguments, timeout: 5)
    }

}
