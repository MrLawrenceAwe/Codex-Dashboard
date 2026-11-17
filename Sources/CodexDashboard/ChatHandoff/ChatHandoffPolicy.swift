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
    case busy, disconnected, readTimedOut, identity, unsafeOwner, nativeHistory, unsupported
    var errorDescription: String? {
        switch self {
        case .busy: "Another account window is using the shared chat server. Wait for its turn to finish, then send again."
        case .disconnected: "The shared chat server disconnected. Check the chat history before sending again; your message was not retried."
        case .readTimedOut: "The shared chat request timed out."
        case .identity: "The selected window’s account could not be verified. No turn was started."
        case .unsafeOwner: "An existing shared writer may still be running. Finish its turns and stop it before retiring the connection."
        case .nativeHistory: "Shared Chats cannot own normal ChatGPT history. Use isolated managed storage."
        case .unsupported: "Change saved accounts through Dashboard. Native sign-in changes are disabled on the shared chat connection."
        }
    }
}
