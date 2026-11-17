import Darwin
import Foundation

struct ManagedChatWorkspace: Sendable {
    let root: URL
    init(root: URL = CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("managed-chat")) {
        self.root = root
    }
    var history: URL { root.appendingPathComponent("history") }
    var server: URL { root.appendingPathComponent("server") }
    var windows: URL { root.appendingPathComponent("windows") }
    var configuration: URL { server.appendingPathComponent("configuration.json") }
    func profile(_ accountID: UUID) -> AccountWindowProfile {
        AccountWindowProfile(accountID: accountID, profilesDirectory: windows)
    }
    func endpoints(ready: Bool) throws -> [ChatHandoffServer.Endpoint] {
        let file = server.appendingPathComponent(ready ? "ready.json" : "connections.json")
        return try JSONDecoder().decode([ChatHandoffServer.Endpoint].self, from: Data(contentsOf: file))
    }
    func environment(_ accountID: UUID) throws -> [String: String] {
        guard brokerPID != nil,
              let endpoint = try endpoints(ready: true).first(where: { $0.id == accountID.uuidString.lowercased() }),
              let url = URLComponents(string: endpoint.url), url.scheme == "ws", url.host == "127.0.0.1",
              url.user == "dashboard", url.password?.isEmpty == false else { throw ManagedChatError.needsRecovery }
        return profile(accountID).environment.merging([
            "CODEX_APP_SERVER_WS_URL": endpoint.url,
            "CODEX_APP_SERVER_FORCE_CLI": "0",
            "CODEX_APP_SERVER_USE_LOCAL_DAEMON": "0",
        ]) { _, scoped in scoped }
    }
    var brokerPID: pid_t? {
        guard let pid = recordedPID("pid"), let command = CodexConfiguration.processArguments(for: pid),
              command.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("--shared-chat-server " + configuration.path) else { return nil }
        return pid
    }
    var ownerPID: pid_t? {
        guard let pid = recordedPID("owner-pid"), let command = CodexConfiguration.processArguments(for: pid),
              command.contains("/codex"), command.contains("app-server") else { return nil }
        return pid
    }
    private func recordedPID(_ name: String) -> pid_t? {
        guard let value = try? String(contentsOf: server.appendingPathComponent(name), encoding: .utf8),
              let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              Darwin.kill(pid, 0) == 0 else { return nil }
        return pid
    }
}

enum ManagedChatError: LocalizedError {
    case needsRecovery, noAccounts, busy, startup, ownership
    var errorDescription: String? {
        switch self {
        case .needsRecovery: "The managed shared workspace needs recovery. Check its history before resending; your message was not retried."
        case .noAccounts: "Save the accounts you want to use before opening shared chat windows."
        case .busy: "Managed work is still running. Wait for it to finish or use Stop and recover shared windows."
        case .startup: "The managed server could not initialize. Normal ChatGPT is still available. See managed-chat/server/diagnostics.log."
        case .ownership: "The previous managed writer could not be safely stopped. A second writer was not started."
        }
    }
}

struct ManagedChatRPC {
    let endpoint: ChatHandoffServer.Endpoint
    func request(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        guard var components = URLComponents(string: endpoint.url), let secret = components.password else {
            throw ManagedChatError.needsRecovery
        }
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw ManagedChatError.needsRecovery }
        var request = URLRequest(url: url)
        request.setValue("Basic " + Data("dashboard:\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        // Cancellation closes the socket, including a receive awaiting a dead server.
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(15), clock: .suspending)
                    socket.cancel(with: .goingAway, reason: nil)
                    throw ManagedChatError.needsRecovery
                }
                group.addTask {
                try await socket.send(.data(data))
                while true {
                    let message = try await socket.receive()
                    let bytes: Data
                    switch message {
                    case .data(let value): bytes = value
                    case .string(let value): bytes = Data(value.utf8)
                    @unknown default: continue
                    }
                    let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    guard response?["id"] as? String == id else { continue }
                    if let error = response?["error"] as? [String: Any] {
                        throw DashboardError.synchronizationFailed(error["message"] as? String ?? "Managed request failed.")
                    }
                    return bytes
                }
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ManagedChatError.needsRecovery }
                return value

            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
