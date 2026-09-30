import Foundation

/// Uses the desktop app's existing local app-server connection. No composer mutation,
/// CLI-owned background session, inherited conversation, or permission override.
@MainActor
final class ReviewLoopDriver: ReviewLoopDriving {
    private let devTools: any DevToolsServing
    private let target: DevToolsTarget
    private let repositoryCheckpoint: any ReviewRepositoryChecking
    init(devTools: any DevToolsServing, target: DevToolsTarget,
         repositoryCheckpoint: any ReviewRepositoryChecking = ReviewRepositoryCheckpoint()) {
        self.devTools = devTools
        self.target = target
        self.repositoryCheckpoint = repositoryCheckpoint
    }

    func projects() async throws -> [ReviewProject] {
        var projects: [ReviewProject] = []
        for row in try await listedRows(method: "project/list", description: "project") {
            guard let id = row["id"] as? String, let name = row["name"] as? String,
                  let roots = row["roots"] as? [[String: Any]], roots.count == 1,
                  let path = roots.first?["path"] as? String, path.hasPrefix("/") else { continue }
            projects.append(ReviewProject(id: id, name: name, path: path))
        }
        return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func models() async throws -> [ReviewModel] {
        var models: [ReviewModel] = []
        for row in try await listedRows(method: "model/list", description: "model") where row["hidden"] as? Bool != true {
            guard let model = row["model"] as? String, let name = row["displayName"] as? String,
                  let efforts = row["supportedReasoningEfforts"] as? [[String: Any]] else { continue }
            models.append(ReviewModel(modelID: model, displayName: name, supportedReasoningEfforts: efforts.compactMap { $0["reasoningEffort"] as? String }))
        }
        return models
    }

    private func listedRows(method: String, description: String) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await request(method, params)
            guard let page = response["data"] as? [[String: Any]] else {
                throw ReviewLoopError("Codex returned an invalid \(description) list.")
            }
            rows.append(contentsOf: page)
            let next = response["nextCursor"] as? String
            guard next == nil || next != cursor else {
                throw ReviewLoopError("Codex repeated its \(description) cursor.")
            }
            cursor = next
        } while cursor != nil
        return rows
    }

    func repository(at path: String) async throws -> ReviewRepositoryState {
        try await repositoryCheckpoint.repository(at: path)
    }

    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        try await repositoryCheckpoint.resolveCommit(commit, at: path)
    }

    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool {
        try await repositoryCheckpoint.isAncestor(commit, of: head, at: path)
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

    func startTurn(threadID: String, projectPath: String, expectedRepository: ReviewRepositoryState, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String {
        var params: [String: Any] = [
            "threadId": threadID,
            "serviceTierForTurn": speed.serviceTier,
            "input": [["type": "text", "text": prompt + "\n\n" + ReviewReportContract.instructions(for: kind), "text_elements": []]],
        ]
        if let selection {
            params["model"] = selection.modelID
            if let effort = selection.reasoningEffort { params["effort"] = effort }
        }
        // This is the last local checkpoint before the renderer can start a turn.
        // It also covers the time spent creating and naming a new review thread.
        let current = try await repositoryCheckpoint.repository(at: projectPath)
        guard current.clean, current == expectedRepository else {
            throw ReviewLoopError("The checkout changed before the review task started. Inspect its changes before continuing.")
        }
        let response = try await request("turn/start", params)
        guard let turn = response["turn"] as? [String: Any], let id = turn["id"] as? String else {
            throw ReviewLoopError("Codex did not acknowledge the review prompt. It will not be resent automatically.")
        }
        return id
    }

    func stopThread(_ threadID: String) async throws {
        // Read only the latest turn metadata so stopping also works while the task
        // is waiting for approval or input, without loading its report.
        let page = try await request("thread/turns/list", [
            "threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
        ])
        guard let turns = page["data"] as? [[String: Any]] else {
            throw ReviewLoopError("Codex returned invalid review turn metadata.")
        }
        guard let turn = turns.first else { return }
        guard let id = turn["id"] as? String, let status = turn["status"] as? String else {
            throw ReviewLoopError("Codex returned an invalid review turn.")
        }
        if status == "inProgress" {
            _ = try await request("turn/interrupt", ["threadId": threadID, "turnId": id])
        }
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
        let expression = try RendererScript.reviewRequest(method: method, params: params)
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
}
