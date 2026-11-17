import Foundation
import Network
import Darwin

/// Desktop windows are clients, never additional writers. The child server alone
/// opens the shared catalog and rollouts. Its credentials live in a private home,
/// separate from both windows' sign-ins.
@MainActor
final class ChatHandoffServer {
    struct Window: Codable, Sendable {
        let id: String
        let home: URL
        let accountIdentifier: String
        let token: String
    }
    struct Configuration: Codable, Sendable {
        let root: URL
        let historyHome: URL
        let executable: URL
        let windows: [Window]
    }
    struct Endpoint: Codable {
        let id: String
        let url: String
        let supportsAccountSwitch: Bool?
    }
    private struct Client {
        let connection: NWConnection
        let window: Window
    }
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let generation: UUID
        let method: String
    }
    private struct Approval {
        let serverID: Any
        let request: [String: Any]
    }
    private struct RequestError: LocalizedError {
        let code: Int?
        let message: String

        var errorDescription: String? { DashboardError.synchronizationFailed(message).localizedDescription }

        func isMissingRollout(for threadID: String) -> Bool {
            code == -32600 && message == "no rollout found for thread id \(threadID)"
        }
    }
    let configuration: Configuration
    private let readTimeout: Duration
    private var listeners: [NWListener] = []
    private var clients: [UUID: Client] = [:]
    private var initializedClients: Set<UUID> = []
    private var owner: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var nextID = 0
    private var pending: [String: Pending] = [:]
    private var approvals: [String: Approval] = [:]
    private var policy = ChatHandoffPolicy()
    private var selected: Window?
    private var ownerCredential: Data?
    private var turnClient: UUID?
    private var turnWindow: Window?
    private var runningThreadIDs: Set<String> = []
    private var loadedThreads: [String: Bool] = [:] // Value indicates an ephemeral thread.
    private var newThreadRollouts: [String: String] = [:]
    private var initializeResult: [String: Any]?
    private var forwarding = 0
    private var writerLock: Int32 = -1
    private var failed = false
    private var shuttingDown = false
    private var authCache: [String: (expires: Date, credential: Data, response: Data)] = [:]
    private var terminationSource: DispatchSourceSignal?

    init(configuration: Configuration, readTimeout: Duration = .seconds(60)) {
        self.configuration = configuration
        self.readTimeout = readTimeout
    }
    var ownerHome: URL { configuration.root.appendingPathComponent("owner") }
    var readyFile: URL { configuration.root.appendingPathComponent("ready.json") }

    func start() async throws -> [Endpoint] {
        let native = FileSystemPath.canonicalPath(CodexConfiguration.codexDirectory.path)
        let isolatedPaths = [configuration.root, configuration.historyHome,
                             configuration.historyHome.appendingPathComponent("sessions"),
                             configuration.historyHome.appendingPathComponent("archived_sessions"),
                             configuration.historyHome.appendingPathComponent("state_5.sqlite"),
                             ownerHome, ownerHome.appendingPathComponent("sessions"),
                             ownerHome.appendingPathComponent("archived_sessions")]
        guard isolatedPaths.allSatisfy({ !FileSystemPath.overlaps(FileSystemPath.canonicalPath($0.path), native) }) else {
            throw ChatHandoffError.nativeHistory
        }
        // A copied database can still refer to the original absolute rollouts.
        // Reject it before a resumed thread can open those original files.
        let database = configuration.historyHome.appendingPathComponent("state_5.sqlite")
        if FileManager.default.fileExists(atPath: database.path) {
            let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-readonly", "-json", database.path, "SELECT rollout_path FROM threads WHERE rollout_path IS NOT NULL AND rollout_path <> '';"],
                timeout: 5)
            guard result.terminationStatus == 0 else { throw ChatHandoffError.unsafeOwner }
            let rows = result.standardOutput.isEmpty ? [] : try JSONDecoder().decode([[String: String]].self, from: result.standardOutput)
            let history = FileSystemPath.canonicalPath(configuration.historyHome.path)
            guard rows.allSatisfy({ row in
                guard let path = row["rollout_path"] else { return false }
                return FileSystemPath.contains(FileSystemPath.canonicalPath(path), in: history)
            }) else { throw ChatHandoffError.nativeHistory }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: configuration.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Advisory lock protects against two Dashboard brokers adopting the same
        // history. Native ChatGPT history is excluded before taking this lock.
        let lock = configuration.historyHome.appendingPathComponent(".dashboard-chat-writer.lock")
        writerLock = Darwin.open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard writerLock >= 0 else { throw ChatHandoffError.unsafeOwner }
        guard flock(writerLock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(writerLock); writerLock = -1
            throw ChatHandoffError.unsafeOwner
        }
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(
            to: configuration.root.appendingPathComponent("pid"), options: .atomic)
        do {
            guard let first = configuration.windows.first else { throw ChatHandoffError.identity }
            trace("startup.initialize")
            try await select(first)
            var endpoints: [Endpoint] = []
            for window in configuration.windows {
                let options = NWProtocolWebSocket.Options()
                options.autoReplyPing = true
                // Each window has a private loopback endpoint and bearer credential.
                options.setClientRequestHandler(.main) { _, headers in
                    let expected = "Basic " + Data("dashboard:\(window.token)".utf8).base64EncodedString()
                    let authenticated = headers.contains { $0.name.lowercased() == "authorization" && $0.value == expected }
                    return .init(status: authenticated ? .accept : .reject, subprotocol: nil)
                }
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection, window: window) }
                }
                let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                    let completion = ListenerCompletion(continuation)
                    listener.stateUpdateHandler = { state in
                        Task { @MainActor in
                            switch state {
                            case .ready:
                                guard let continuation = completion.take() else { return }
                                continuation.resume(returning: listener.port!.rawValue)
                            case .failed(let error): completion.take()?.resume(throwing: error)
                            default: break
                            }
                        }
                    }
                    listener.start(queue: .main)
                }
                listeners.append(listener)
                // Store endpoint URLs only in the private activation file; never log them.
                endpoints.append(Endpoint(id: window.id, url: "ws://dashboard:\(window.token)@127.0.0.1:\(port)",
                                          supportsAccountSwitch: window.id == "main"))
            }
            trace("startup.ready")
            return endpoints
        } catch {
            trace("startup.failed")
            try? await shutdown()
            throw error
        }
    }

    private func trace(_ message: String) {
        ChatHandoffDiagnostics(root: configuration.root).record(message)
    }

    private func accept(_ connection: NWConnection, window: Window) {
        trace("connection accepted")
        let id = UUID()
        clients[id] = Client(connection: connection, window: windowForConnection(window))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.disconnectClient(id) }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(id)
    }

    private func windowForConnection(_ window: Window) -> Window {
        // The main window reconnects after Dashboard installs a saved credential.
        // Capture its identity for this connection so existing clients cannot
        // silently start sending under the newly selected account.
        guard window.id == "main",
              let data = try? Data(contentsOf: window.home.appendingPathComponent("auth.json")),
              let identity = AccountIdentityDecoder.identity(in: data),
              configuration.windows.contains(where: { $0.accountIdentifier == identity.identifier }) else { return window }
        return Window(id: window.id, home: window.home, accountIdentifier: identity.identifier, token: window.token)
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || metadata?.opcode == .close || (data == nil && context == nil) {
                    self.disconnectClient(id)
                    return
                }
                if let data, metadata?.opcode == .text || metadata?.opcode == .binary {
                    // Keep receiving control frames and approval replies while a
                    // request waits on the writer. Admission is guarded in handle.
                    Task { @MainActor in await self.handle(data, from: id) }
                }
                self.receive(id)
            }
        }
    }

    private func disconnectClient(_ id: UUID) {
        initializedClients.remove(id)
        clients.removeValue(forKey: id)?.connection.cancel()
        guard turnClient == id else { return }
        turnClient = nil
        for candidate in initializedClients {
            restoreTurnClient(candidate)
            if turnClient != nil { break }
        }
    }

    private func restoreTurnClient(_ id: UUID) {
        guard !failed, turnClient == nil, let window = clients[id]?.window, let turnWindow,
              window.id == turnWindow.id, window.accountIdentifier == turnWindow.accountIdentifier,
              (try? credential(window)) != nil else { return }
        turnClient = id
        for approval in approvals.values { send(approval.request, to: id) }
    }

    private func finishTurnRouting() {
        turnClient = nil
        turnWindow = nil
        runningThreadIDs.removeAll()
        approvals.removeAll()
    }

    private func send(_ object: [String: Any], to id: UUID) {
        guard let client = clients[id], let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "json-rpc", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ data: Data, from id: UUID) async {
        guard let client = clients[id], let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let method = request["method"] as? String else {
            if !failed, turnClient == id, let responseID = request["id"] as? String,
               let approval = approvals[responseID], (try? credential(client.window)) != nil {
                var response = request
                response["id"] = approval.serverID
                do {
                    try write(response)
                    approvals.removeValue(forKey: responseID)
                } catch { fail() }
            }
            return
        }
        guard let requestID = request["id"] else { return }
        trace("request " + ChatHandoffDiagnostics.method(method))
        if method == "dashboard/status" {
            send(["id": requestID, "result": [
                "healthy": !failed && !shuttingDown && owner?.isRunning == true,
                "safeToStop": (policy.isIdle && forwarding == 0) || (failed && owner?.isRunning != true),
                "activeTurns": policy.runningTurns.count,
            ]], to: id)
            return
        }
        if method == "dashboard/interrupt" {
            do {
                for threadID in Array(runningThreadIDs) {
                    _ = try await call("turn/interrupt", params: ["threadId": threadID], readOnly: true)
                }
                let deadline = SuspendingClock.now + .seconds(10)
                while !policy.isIdle, SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
                guard policy.isIdle else { throw ChatHandoffError.busy }
                send(["id": requestID, "result": ["stopped": true]], to: id)
            } catch {
                send(["id": requestID, "error": ["code": -32001, "message": error.localizedDescription]], to: id)
            }
            return
        }

        do {
            guard !failed, !shuttingDown else { throw ChatHandoffError.disconnected }
            var params = request["params"] as? [String: Any] ?? [:]
            if method == "initialize" {
                _ = try credential(client.window)
                if initializeResult == nil { try await waitForTransition() }
                if initializeResult == nil {
                    guard policy.isIdle, forwarding == 0 else { throw ChatHandoffError.busy }
                    try policy.beginSwitch()
                    defer { policy.finishSwitch() }
                    try await select(client.window)
                }
                send(["id": requestID, "result": initializeResult ?? [:]], to: id)
                if clients[id] != nil {
                    initializedClients.insert(id)
                    restoreTurnClient(id)
                }
                return
            }
            guard !method.hasPrefix("accountSession/"), !(method.hasPrefix("account/") && !method.hasSuffix("/read")) else { throw ChatHandoffError.unsupported }
            if method == "getAuthStatus" || (method.hasPrefix("account/") && method.hasSuffix("/read")) {
                let result = try await isolatedAccountRequest(method, params: params, window: client.window)
                send(["id": requestID, "result": result], to: id)
                return
            }
            let reads = ChatHandoffPolicy.isReadOnly(method)
            if reads { try await waitForTransition() }
            let startsTurn = method == "turn/start" || method == "review/start"
            if startsTurn || method == "thread/start" { _ = try credential(client.window) }
            if startsTurn {
                guard forwarding == 0 else { throw ChatHandoffError.busy }
                try policy.beginTurn()
                turnWindow = client.window
                turnClient = id
                if let threadID = params["threadId"] as? String { runningThreadIDs.insert(threadID) }
            } else if !policy.isIdle {
                guard !policy.switching && (reads || method == "turn/interrupt" || (method == "turn/steer" && turnClient == id)) else { throw ChatHandoffError.busy }
            }
            defer {
                if startsTurn {
                    policy.finishStarting()
                    if policy.runningTurns.isEmpty { finishTurnRouting() }
                }
            }
            if owner == nil || ((startsTurn || method == "thread/start")
                && (selected?.id != client.window.id || selected?.accountIdentifier != client.window.accountIdentifier)) {
                guard forwarding == 0 else { throw ChatHandoffError.busy }
                try policy.beginSwitch()
                defer { policy.finishSwitch() }
                try await select(client.window)
            }
            if method == "thread/list" { params["currentAccountOnly"] = false }
            if startsTurn, let threadID = params["threadId"] as? String, loadedThreads[threadID] == nil {
                _ = try await call("thread/resume", params: ["threadId": threadID])
                loadedThreads[threadID] = false
            }
            forwarding += 1
            defer { forwarding -= 1 }
            if startsTurn { trace("turn.admitted window=" + client.window.id) }
            let result = try await call(method, params: params, readOnly: reads)
            if startsTurn { policy.observe(method: "turn/started", params: result) }
            if ["thread/resume", "thread/start"].contains(method), let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String {
                let ephemeral = thread["ephemeral"] as? Bool ?? (params["ephemeral"] as? Bool == true)
                loadedThreads[threadID] = ephemeral
                if method == "thread/start", !ephemeral {
                    newThreadRollouts[threadID] = thread["path"] as? String
                }
            }
            if ["thread/unsubscribe", "thread/archive", "thread/delete"].contains(method), let threadID = params["threadId"] as? String {
                loadedThreads.removeValue(forKey: threadID)
                newThreadRollouts.removeValue(forKey: threadID)
            }
            send(["id": requestID, "result": result], to: id)
        } catch {
            trace("request.failed " + ChatHandoffDiagnostics.method(method))
            send(["id": requestID, "error": ["code": -32001, "message": error.localizedDescription]], to: id)
        }
    }

    private func waitForTransition() async throws {
        let deadline = SuspendingClock.now + .seconds(60)
        while policy.switching {
            guard !failed, SuspendingClock.now < deadline else { throw ChatHandoffError.disconnected }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !failed else { throw ChatHandoffError.disconnected }
    }

    private func credential(_ window: Window) throws -> Data {
        let data = try Data(contentsOf: window.home.appendingPathComponent("auth.json"))
        guard AccountIdentityDecoder.identity(in: data)?.identifier == window.accountIdentifier else { throw ChatHandoffError.identity }
        return data
    }

    private func isolatedAccountRequest(_ method: String, params: [String: Any], window: Window) async throws -> [String: Any] {
        let cacheKey = window.id + ":" + method + ":" + (try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)).base64EncodedString()
        let selectedCredential = try credential(window)
        if let cached = authCache[cacheKey], cached.expires > .now, cached.credential == selectedCredential {
            return (try JSONSerialization.jsonObject(with: cached.response) as? [String: Any])?["result"] as? [String: Any] ?? [:]
        }
        let home = configuration.root.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        try ActiveCodexCredentialFile(url: home.appendingPathComponent("auth.json"), fileManager: .default).write(selectedCredential)
        try "cli_auth_credentials_store = \"file\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let session = try CodexAppServerSession(executableURL: configuration.executable, codexHomeURL: home)
        defer { session.terminate() }
        _ = try await session.request(id: 1, method: "initialize", params: ["clientInfo": ["name": "dashboard-account-usage", "version": "1"]], timeout: .seconds(15))
        try session.notify(method: "initialized")
        let data = try await session.request(id: 2, method: method, serializedParams: JSONSerialization.data(withJSONObject: params), timeout: .seconds(30))
        if let refreshed = try? Data(contentsOf: home.appendingPathComponent("auth.json")), AccountIdentityDecoder.identity(in: refreshed)?.identifier == window.accountIdentifier {
            try persist(refreshed, for: window, expected: selectedCredential)
        }
        if method == "getAuthStatus" || method == "account/read" {
            authCache[cacheKey] = (.now.addingTimeInterval(15), try credential(window), data)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any] ?? [:]
    }

    private func persist(_ data: Data, for window: Window, expected: Data) throws {
        let file = window.home.appendingPathComponent("auth.json")
        // A sign-out or account change must not be undone by a late refresh.
        guard let current = try? Data(contentsOf: file),
              current == expected, current != data,
              AccountIdentityDecoder.identity(in: current)?.identifier == window.accountIdentifier else { return }
        try ActiveCodexCredentialFile(url: file, fileManager: .default).write(data)
    }

    private func select(_ window: Window) async throws {
        if owner?.isRunning == true {
            for (threadID, path) in newThreadRollouts where !FileManager.default.fileExists(atPath: path) {
                // Codex creates rollouts lazily. A no-op response item flushes
                // the native thread metadata without adding messages or turns.
                _ = try await call("thread/inject_items", params: ["threadId": threadID, "items": [["type": "other"]]])
            }
        }
        try await stopOwner()
        let previousThreads = loadedThreads
        loadedThreads.removeAll()
        newThreadRollouts.removeAll()
        let fm = FileManager.default
        try fm.createDirectory(at: ownerHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The shared catalog keeps its original paths. No rollout or database is
        // copied or merged; existing creator metadata is preserved.
        for name in ["sessions", "archived_sessions"] {
            try fm.createDirectory(at: configuration.historyHome.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for name in ["sessions", "archived_sessions", "config.toml", "skills", "rules", "plugins"] {
            let target = configuration.historyHome.appendingPathComponent(name)
            let link = ownerHome.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: link.path) {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }
        let selectedCredential = try credential(window)
        try ActiveCodexCredentialFile(url: ownerHome.appendingPathComponent("auth.json"), fileManager: .default).write(selectedCredential)
        let incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = ownerHome.path
        environment["CODEX_SQLITE_HOME"] = configuration.historyHome.path
        environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "Codex Desktop"
        for key in ["CODEX_APP_SERVER_WS_URL", "CODEX_APP_SERVER_FORCE_CLI", "CODEX_APP_SERVER_USE_LOCAL_DAEMON"] { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = errors
        generation = UUID(); let current = generation
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.trace("writer.exit status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
                self.fail()
            }
        }
        let diagnostics = ChatHandoffDiagnostics(root: configuration.root)
        errorOutput = errors.fileHandleForReading
        errorOutput?.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { Task { @MainActor in diagnostics.stderr(data) } }
        }
        output = outgoing.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consume(data, generation: current) }
        }
        try process.run()
        try errors.fileHandleForWriting.close()
        try outgoing.fileHandleForWriting.close()
        try incoming.fileHandleForReading.close()
        owner = process; input = incoming.fileHandleForWriting; selected = window; ownerCredential = selectedCredential
        try Data(String(process.processIdentifier).utf8).write(to: configuration.root.appendingPathComponent("owner-pid"), options: .atomic)
        let response = try await call("initialize", params: ["clientInfo": ["name": "Codex Desktop", "version": "1"], "capabilities": ["experimentalApi": true]])
        initializeResult = response
        try write(["method": "initialized"])
        _ = try await call("account/read", params: ["refreshToken": false])
        guard AccountIdentityDecoder.identity(in: try Data(contentsOf: ownerHome.appendingPathComponent("auth.json")))?.identifier == window.accountIdentifier else { throw ChatHandoffError.identity }
        for (threadID, ephemeral) in previousThreads where !ephemeral {
            do {
                _ = try await call("thread/resume", params: ["threadId": threadID])
                loadedThreads[threadID] = false
            } catch let error as RequestError where error.isMissingRollout(for: threadID) {
                // A newly opened chat may never have written history before the switch.
                continue
            }
        }
    }

    private func stopOwner() async throws {
        guard let process = owner else { return }
        guard policy.runningTurns.isEmpty || !process.isRunning else { throw ChatHandoffError.busy }
        // Wait for exit before importing another account. A process which refuses
        // to stop leaves the switch failed, never starts a competing writer.
        trace("writer.stop requested")
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close()
        if process.isRunning { process.terminate() }
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard !process.isRunning else { fail(); throw ChatHandoffError.disconnected }
        if let window = selected, let data = try? Data(contentsOf: ownerHome.appendingPathComponent("auth.json")), AccountIdentityDecoder.identity(in: data)?.identifier == window.accountIdentifier {
            if let expected = ownerCredential { try persist(data, for: window, expected: expected) }
        }
        let abandoned = pending.values.map(\.continuation)
        pending.removeAll()
        for continuation in abandoned { continuation.resume(throwing: ChatHandoffError.disconnected) }
        try? FileManager.default.removeItem(at: configuration.root.appendingPathComponent("owner-pid"))
        errorOutput?.readabilityHandler = nil
        try? errorOutput?.close()
        errorOutput = nil
        ownerCredential = nil
        owner = nil; input = nil; output = nil; buffer = Data()
    }

    private func call(_ method: String, params: [String: Any], readOnly: Bool = false) async throws -> [String: Any] {
        nextID += 1; let id = "broker-\(nextID)"; let current = generation
        let timeout = readOnly ? readTimeout : .seconds(60)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(continuation: continuation, generation: current, method: method)
            do { try write(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.continuation.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: timeout, clock: .suspending)
                guard let self, let request = self.pending[id],
                      request.generation == current, self.generation == current else { return }
                self.trace("request.timeout " + ChatHandoffDiagnostics.method(request.method) + " readOnly=\(readOnly)")
                if readOnly {
                    self.pending.removeValue(forKey: id)
                    request.continuation.resume(throwing: ChatHandoffError.readTimedOut)
                } else {
                    self.fail()
                }
            }
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = object["error"] as? [String: Any] {
            throw RequestError(code: error["code"] as? Int,
                               message: error["message"] as? String ?? "The shared chat request failed.")
        }
        return object["result"] as? [String: Any] ?? [:]
    }
    private func write(_ value: [String: Any]) throws {
        guard let owner, owner.isRunning, let input else { throw ChatHandoffError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        try input.write(contentsOf: data)
    }
    private func fail() {
        if !failed { trace("broker.failed pending=\(pending.count) writerRunning=\(owner?.isRunning == true)") }
        failed = true
        try? FileManager.default.removeItem(at: readyFile)
        let abandoned = pending.values.map(\.continuation)
        pending.removeAll()
        for continuation in abandoned { continuation.resume(throwing: ChatHandoffError.disconnected) }
    }

    private func consume(_ data: Data, generation current: UUID) {
        guard current == generation else { return }
        if data.isEmpty {
            output?.readabilityHandler = nil
            fail()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard var object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = object["method"] as? String {
                if let serverID = object["id"] {
                    guard turnWindow != nil, !failed else { continue }
                    let id = "approval-\(UUID().uuidString)"
                    // Keep server ids separate from client request ids.
                    object["id"] = id
                    approvals[id] = Approval(serverID: serverID, request: object)
                    if let turnClient { send(object, to: turnClient) }
                    continue
                }
                if !method.hasSuffix("/delta") { trace("notification " + ChatHandoffDiagnostics.method(method)) }
                let parameters = object["params"] as? [String: Any] ?? [:]
                if method == "turn/started", let threadID = parameters["threadId"] as? String { runningThreadIDs.insert(threadID) }
                policy.observe(method: method, params: parameters)
                if method == "turn/completed", policy.isIdle { finishTurnRouting() }
                // Restarting the private writer changes its global account, but
                // never changes a desktop client's sign-in. Forwarding this
                // internal event makes Codex retire an already accepted send as
                // "active account changed". Client identity comes exclusively
                // from its own credential-backed account reads above.
                if method == "account/updated" || method == "account/login/completed" { continue }
                for (id, client) in clients {
                    let accountScoped = method.hasPrefix("account/") || method.hasPrefix("modelProvider/authRecovery")
                    if accountScoped && client.window.accountIdentifier != selected?.accountIdentifier { continue }
                    send(object, to: id)
                }
            } else if let id = object["id"] as? String { pending.removeValue(forKey: id)?.continuation.resume(returning: line) }
        }
    }
    func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                do { try await self.shutdown(); exit(0) }
                catch { /* Keep the writer alive until every active turn finishes. */ }
            }
        }
        terminationSource = source
        source.resume()
    }

    func shutdown() async throws {
        guard !shuttingDown, forwarding == 0,
              policy.isIdle || (failed && owner?.isRunning != true) else { throw ChatHandoffError.busy }
        shuttingDown = true
        do { try await stopOwner() }
        catch { shuttingDown = false; throw error }
        try? FileManager.default.removeItem(at: readyFile)
        for listener in listeners { listener.cancel() }
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        initializedClients.removeAll()
        for name in ["ready.json", "connections.json", "pid"] {
            try? FileManager.default.removeItem(at: configuration.root.appendingPathComponent(name))
        }
        if writerLock >= 0 { Darwin.close(writerLock); writerLock = -1 }
    }
}

@MainActor
private final class ListenerCompletion {
    var continuation: CheckedContinuation<UInt16, Error>?
    init(_ value: CheckedContinuation<UInt16, Error>) { continuation = value }
    func take() -> CheckedContinuation<UInt16, Error>? {
        defer { continuation = nil }
        return continuation
    }
}

