import Foundation

actor DevToolsClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        session = URLSession(configuration: configuration)
    }

    func mainRendererTargets() async -> [DevToolsTarget] {
        guard let endpoint = URL(
            string: "http://\(AppConfiguration.devToolsHost):\(AppConfiguration.devToolsPort)/json/list"
        ) else { return [] }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return try JSONDecoder().decode([DevToolsTarget].self, from: data)
                .filter(Self.isMainRenderer)
        } catch {
            return []
        }
    }

    nonisolated static func isMainRenderer(_ target: DevToolsTarget) -> Bool {
        target.type == "page"
            && target.url == "app://-/index.html"
            && target.webSocketDebuggerUrl != nil
    }

    func evaluateBoolean(
        _ expression: String,
        in target: DevToolsTarget,
        bypassContentSecurityPolicy: Bool = false
    ) async throws -> Bool {
        try await withDevToolsTimeout(.seconds(4)) { [self] in
            try await evaluateBooleanWithoutTimeout(
                expression,
                in: target,
                bypassContentSecurityPolicy: bypassContentSecurityPolicy
            )
        }
    }

    private func evaluateBooleanWithoutTimeout(
        _ expression: String,
        in target: DevToolsTarget,
        bypassContentSecurityPolicy: Bool
    ) async throws -> Bool {
        try await withConnection(to: target) { task in
            if bypassContentSecurityPolicy {
                _ = try await command(id: 1, method: "Page.enable", through: task)
                _ = try await command(
                    id: 2,
                    method: "Page.setBypassCSP",
                    params: ["enabled": true],
                    through: task
                )
            }
            let response: [String: Any]
            do {
                response = try await command(
                    id: 3,
                    method: "Runtime.evaluate",
                    params: [
                        "expression": expression,
                        "returnByValue": true,
                        "awaitPromise": true,
                    ],
                    through: task
                )
                if bypassContentSecurityPolicy {
                    try await setContentSecurityPolicyBypass(false, commandID: 4, through: task)
                }
            } catch {
                if bypassContentSecurityPolicy {
                    try? await setContentSecurityPolicyBypass(false, commandID: 4, through: task)
                }
                throw error
            }
            if response["exceptionDetails"] != nil {
                throw DashboardError.enableFailed("The adapter raised an exception in the renderer.")
            }
            guard
                let remoteResult = response["result"] as? [String: Any],
                let value = remoteResult["value"] as? Bool
            else {
                throw DashboardError.invalidDevToolsResponse
            }
            return value
        }
    }

    private func setContentSecurityPolicyBypass(
        _ enabled: Bool,
        commandID: Int,
        through task: URLSessionWebSocketTask
    ) async throws {
        _ = try await command(
            id: commandID,
            method: "Page.setBypassCSP",
            params: ["enabled": enabled],
            through: task
        )
    }

    private func withConnection<T>(
        to target: DevToolsTarget,
        operation: (URLSessionWebSocketTask) async throws -> T
    ) async throws -> T {
        guard
            let address = target.webSocketDebuggerUrl,
            let webSocketURL = URL(string: address)
        else {
            throw DashboardError.invalidDevToolsResponse
        }

        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        return try await withTaskCancellationHandler {
            try await operation(task)
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func command(
        id: Int,
        method: String,
        params: [String: Any]? = nil,
        through task: URLSessionWebSocketTask
    ) async throws -> [String: Any] {
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DashboardError.invalidDevToolsResponse
        }
        try await task.send(.string(string))

        while true {
            let message = try await task.receive()
            let responseData: Data
            switch message {
            case .data(let value): responseData = value
            case .string(let value): responseData = Data(value.utf8)
            @unknown default: continue
            }
            guard
                let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                payload["id"] as? Int == id
            else { continue }
            if let error = payload["error"] as? [String: Any] {
                throw DashboardError.devToolsCommandFailed(
                    error["message"] as? String ?? "Unknown DevTools error"
                )
            }
            guard let result = payload["result"] as? [String: Any] else {
                throw DashboardError.invalidDevToolsResponse
            }
            return result
        }
    }
}
