import Foundation

/// One server owns every rollout. Account changes are admitted only at an idle
/// boundary; a rejected request is never queued or replayed as a second turn.
struct ChatHandoffPolicy {
    private(set) var runningTurns: Set<String> = []
    private var completedTurns: Set<String> = []
    private(set) var startingTurn = false
    private(set) var switching = false
    var isIdle: Bool { runningTurns.isEmpty && !startingTurn && !switching }

    static func isReadOnly(_ method: String) -> Bool {
        method.hasSuffix("/read") || method.hasSuffix("/list") ||
            ["getAuthStatus", "plugin/installed", "externalAgentConfig/detect", "fs/readFile", "fs/stat", "fs/listDirectory", "fs/canonicalizePath"].contains(method)
    }

    mutating func beginTurn() throws {
        guard isIdle else { throw ChatHandoffError.busy }
        startingTurn = true
    }
    mutating func finishStarting() { startingTurn = false }
    mutating func beginSwitch() throws {
        guard runningTurns.isEmpty, !switching else { throw ChatHandoffError.busy }
        switching = true
    }
    mutating func finishSwitch() { switching = false }
    mutating func observe(method: String, params: [String: Any]) {
        guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
        if method == "turn/started", !completedTurns.contains(id) { runningTurns.insert(id) }
        if method == "turn/completed" { runningTurns.remove(id); completedTurns.insert(id) }
    }
}

enum ChatHandoffError: LocalizedError {
    case busy, disconnected, identity, unsafeOwner, unsupported, independentHistory, projectAliases
    var errorDescription: String? {
        switch self {
        case .busy: "Another account window is using the shared chat server. Wait for its turn to finish, then send again."
        case .disconnected: "The shared chat server disconnected. Check the chat history before sending again; your message was not retried."
        case .identity: "The selected window’s account could not be verified. No turn was started."
        case .unsafeOwner: "Shared chats cannot start while an independent Codex window still owns this history. Restart all Codex windows through Dashboard first."
        case .projectAliases: "Some project registrations could not be matched to the original project list. Shared Chats activation stopped."
        case .independentHistory: "A separate account window has its own chats. Shared chats were not enabled; no history was merged or removed."
        case .unsupported: "Change saved accounts through Dashboard. Native sign-in changes are disabled on the shared chat connection."
        }
    }
}

/// Require a stable idle boundary; a busy or unavailable window resets the gate.
struct ChatHandoffActivationGate {
    private var idleObservations = 0
    mutating func reset() { idleObservations = 0 }
    mutating func observeIdle() -> Bool {
        idleObservations += 1
        return idleObservations >= 2
    }
}
