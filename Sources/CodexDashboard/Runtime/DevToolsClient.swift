import Foundation

func withDevToolsTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: duration)
            throw DashboardError.devToolsTimedOut
        }

        guard let result = try await group.next() else {
            throw DashboardError.invalidDevToolsResponse
        }
        group.cancelAll()
        return result
    }
}

struct DevToolsTarget: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let url: String?
    let webSocketURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, url
        case webSocketURL = "webSocketDebuggerUrl"
    }
}

protocol DevToolsServing: Sendable {
    func mainRendererTargets() async -> [DevToolsTarget]
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async throws -> Bool
    func evaluateString(_ expression: String, in target: DevToolsTarget) async throws -> String?
}

extension DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget) async throws -> String? { nil }
}

enum DevToolsEvaluationValue: Equatable, Sendable {
    case boolean(Bool)
    case string(String)
    case null
}

protocol DevToolsConnectionServing: Sendable {
    func evaluate(_ expression: String) async throws -> DevToolsEvaluationValue
    func cancel() async
}

actor PersistentDevToolsConnection: DevToolsConnectionServing {
    private let task: URLSessionWebSocketTask
    private var nextCommandID = 0
    private var pending: [Int: CheckedContinuation<DevToolsEvaluationValue, any Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    init(session: URLSession, webSocketURL: URL) {
        task = session.webSocketTask(with: webSocketURL)
        task.resume()
    }

    deinit {
        readerTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    func evaluate(_ expression: String) async throws -> DevToolsEvaluationValue {
        guard !isClosed else { throw DashboardError.invalidDevToolsResponse }
        startReaderIfNeeded()
        nextCommandID += 1
        let commandID = nextCommandID
        let request = try Self.commandMessage(id: commandID, expression: expression)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[commandID] = continuation
                Task { await self.send(request) }
            }
        } onCancel: {
            Task { await self.cancelRequest(commandID) }
        }
    }

    func cancel() {
        close(with: CancellationError())
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in await self?.receiveMessages() }
    }

    private func send(_ request: URLSessionWebSocketTask.Message) async {
        do {
            try await task.send(request)
        } catch {
            close(with: error)
        }
    }

    private func receiveMessages() async {
        do {
            while !Task.isCancelled, !isClosed {
                let message = try await task.receive()
                try handle(message)
            }
        } catch {
            close(with: error)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let responseData: Data
        switch message {
        case .data(let value): responseData = value
        case .string(let value): responseData = Data(value.utf8)
        @unknown default: return
        }
        guard let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else { return }
        let commandID = (payload["id"] as? NSNumber)?.intValue ?? payload["id"] as? Int
        guard let commandID, let continuation = pending.removeValue(forKey: commandID) else { return }
        if let error = payload["error"] as? [String: Any] {
            continuation.resume(throwing: DashboardError.devToolsCommandFailed(
                error["message"] as? String ?? "Unknown DevTools error"
            ))
            return
        }
        guard let result = payload["result"] as? [String: Any] else {
            continuation.resume(throwing: DashboardError.invalidDevToolsResponse)
            return
        }
        if result["exceptionDetails"] != nil {
            continuation.resume(throwing: DashboardError.enableFailed(
                "The dashboard injection raised an exception in the renderer."
            ))
            return
        }
        guard let remoteResult = result["result"] as? [String: Any] else {
            continuation.resume(throwing: DashboardError.invalidDevToolsResponse)
            return
        }
        do {
            continuation.resume(returning: try Self.evaluationValue(from: remoteResult))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    nonisolated static func evaluationValue(
        from remoteResult: [String: Any]
    ) throws -> DevToolsEvaluationValue {
        if remoteResult["value"] is NSNull
            || remoteResult["subtype"] as? String == "null"
        {
            return .null
        }
        switch remoteResult["value"] {
        case let value as Bool:
            return .boolean(value)
        case let value as String:
            return .string(value)
        case nil where remoteResult["type"] == nil || remoteResult["type"] as? String == "undefined":
            return .null
        default:
            throw DashboardError.invalidDevToolsResponse
        }
    }

    private func cancelRequest(_ commandID: Int) {
        pending.removeValue(forKey: commandID)?.resume(throwing: CancellationError())
    }

    private func close(with error: any Error) {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        let continuations = pending.values
        pending = [:]
        continuations.forEach { $0.resume(throwing: error) }
    }

    private static func commandMessage(
        id: Int,
        expression: String
    ) throws -> URLSessionWebSocketTask.Message {
        let request: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DashboardError.invalidDevToolsResponse
        }
        return .string(string)
    }
}

actor DevToolsClient: DevToolsServing {
    private struct CachedConnection {
        let address: String
        let connection: any DevToolsConnectionServing
    }

    private let session: URLSession
    private let connectionFactory: @Sendable (URLSession, URL) -> any DevToolsConnectionServing
    private var connectionsByTargetID: [String: CachedConnection] = [:]

    init(
        session: URLSession? = nil,
        connectionFactory: @escaping @Sendable (URLSession, URL) -> any DevToolsConnectionServing = {
            PersistentDevToolsConnection(session: $0, webSocketURL: $1)
        }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
            self.session = URLSession(configuration: configuration)
        }
        self.connectionFactory = connectionFactory
    }

    deinit {
        session.invalidateAndCancel()
    }

    func mainRendererTargets() async -> [DevToolsTarget] {
        guard let endpoint = URL(
            string: "http://\(CodexConfiguration.devToolsAddress):\(CodexConfiguration.devToolsPort)/json/list"
        ) else { return [] }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let targets = try JSONDecoder().decode([DevToolsTarget].self, from: data)
                .filter(Self.isMainRenderer)
            retainConnections(for: targets)
            return targets
        } catch {
            return []
        }
    }

    nonisolated static func isMainRenderer(_ target: DevToolsTarget) -> Bool {
        target.type == "page"
            && target.url == "app://-/index.html"
            && target.webSocketURL != nil
    }

    func evaluateBoolean(
        _ expression: String,
        in target: DevToolsTarget
    ) async throws -> Bool {
        try await withDevToolsTimeout(.seconds(4)) { [self] in
            try await evaluateBooleanWithoutTimeout(
                expression,
                in: target
            )
        }
    }

    func evaluateString(
        _ expression: String,
        in target: DevToolsTarget
    ) async throws -> String? {
        try await withDevToolsTimeout(.seconds(4)) { [self] in
            try await evaluateStringWithoutTimeout(expression, in: target)
        }
    }

    private func evaluateStringWithoutTimeout(
        _ expression: String,
        in target: DevToolsTarget
    ) async throws -> String? {
        switch try await evaluateValueWithoutTimeout(expression, in: target) {
        case .string(let value): return value
        case .null: return nil
        case .boolean: throw DashboardError.invalidDevToolsResponse
        }
    }

    private func evaluateBooleanWithoutTimeout(
        _ expression: String,
        in target: DevToolsTarget
    ) async throws -> Bool {
        switch try await evaluateValueWithoutTimeout(expression, in: target) {
        case .boolean(let value): return value
        case .string, .null: throw DashboardError.invalidDevToolsResponse
        }
    }

    private func evaluateValueWithoutTimeout(
        _ expression: String,
        in target: DevToolsTarget
    ) async throws -> DevToolsEvaluationValue {
        let cached = try connection(for: target)
        do {
            return try await cached.connection.evaluate(expression)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if connectionsByTargetID[target.id]?.address == cached.address {
                connectionsByTargetID.removeValue(forKey: target.id)
                await cached.connection.cancel()
            }
            throw error
        }
    }

    private func connection(for target: DevToolsTarget) throws -> CachedConnection {
        guard let address = target.webSocketURL, let webSocketURL = URL(string: address) else {
            throw DashboardError.invalidDevToolsResponse
        }
        if let cached = connectionsByTargetID[target.id], cached.address == address {
            return cached
        }
        if let stale = connectionsByTargetID.removeValue(forKey: target.id) {
            Task { await stale.connection.cancel() }
        }
        let cached = CachedConnection(
            address: address,
            connection: connectionFactory(session, webSocketURL)
        )
        connectionsByTargetID[target.id] = cached
        return cached
    }

    private func retainConnections(for targets: [DevToolsTarget]) {
        let addressesByTargetID = Dictionary(uniqueKeysWithValues: targets.compactMap { target in
            target.webSocketURL.map { (target.id, $0) }
        })
        let staleConnections = connectionsByTargetID.filter { targetID, cached in
            addressesByTargetID[targetID] != cached.address
        }
        for (targetID, cached) in staleConnections {
            connectionsByTargetID.removeValue(forKey: targetID)
            Task { await cached.connection.cancel() }
        }
    }
}
