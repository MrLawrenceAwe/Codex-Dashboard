import AppKit
import CryptoKit
import Foundation
import SwiftUI

private let chatGPTBundleIdentifier = "com.openai.codex"
private let chatGPTExecutable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
private let devToolsHost = "127.0.0.1"
private let devToolsPort = 47_832

struct DevToolsTarget: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let title: String?
    let url: String?
    let webSocketDebuggerUrl: String?
}

struct DashboardTask: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let workspace: String
    let cwd: String
    let updatedAt: Int64
    let createdAt: Int64
    let isPinned: Bool
    let model: String?
    let status: String
}

private struct StoredThread: Decodable, Sendable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let updatedAt: Int64
    let createdAt: Int64
    let isPinned: Int
    let model: String?
}

private struct ThreadActivity: Decodable, Sendable {
    let threadId: String
    let lastActivity: Int64
}

struct TaskSnapshot: Sendable {
    let tasks: [DashboardTask]
    let warning: String?
}

enum TaskStoreError: LocalizedError {
    case missingDatabase(String)
    case queryFailed(String, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase(let database):
            return "The Codex database is missing: \(database)"
        case .queryFailed(let database, let message):
            return "Could not read \(database): \(message)"
        case .invalidResponse(let database):
            return "Codex returned unreadable data from \(database)."
        }
    }
}

actor TaskStore {
    private let stateDatabase: String
    private let logsDatabase: String

    init(
        stateDatabase: String = "/Users/lawrenceawe/.codex/state_5.sqlite",
        logsDatabase: String = "/Users/lawrenceawe/.codex/logs_2.sqlite"
    ) {
        self.stateDatabase = stateDatabase
        self.logsDatabase = logsDatabase
    }

    func load() throws -> TaskSnapshot {
        let threadSQL = """
        SELECT id,
               COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), 'Untitled task') AS title,
               preview,
               cwd,
               updated_at AS updatedAt,
               created_at AS createdAt,
               is_pinned AS isPinned,
               model
        FROM threads
        WHERE archived = 0 AND preview <> ''
        ORDER BY recency_at_ms DESC
        LIMIT 60;
        """
        let activitySQL = """
        SELECT thread_id AS threadId, MAX(ts) AS lastActivity
        FROM logs
        WHERE thread_id IS NOT NULL AND thread_id <> ''
          AND ts >= CAST(strftime('%s','now') AS INTEGER) - 120
        GROUP BY thread_id;
        """
        let threads: [StoredThread] = try query(database: stateDatabase, sql: threadSQL)
        let activity: [ThreadActivity]
        let warning: String?
        do {
            activity = try query(database: logsDatabase, sql: activitySQL)
            warning = nil
        } catch {
            activity = []
            warning = "Task activity is temporarily unavailable. \(error.localizedDescription)"
        }

        let latestActivity = Dictionary(uniqueKeysWithValues: activity.map { ($0.threadId, $0.lastActivity) })
        let now = Int64(Date().timeIntervalSince1970)
        let tasks = threads.map { thread in
            let lastLog = latestActivity[thread.id] ?? 0
            let status: String
            if now - lastLog <= 12 {
                status = "running"
            } else if now - thread.updatedAt <= 3_600 {
                status = "recent"
            } else {
                status = "idle"
            }
            let workspace = URL(fileURLWithPath: thread.cwd).lastPathComponent
            return DashboardTask(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                workspace: workspace.isEmpty ? thread.cwd : workspace,
                cwd: thread.cwd,
                updatedAt: thread.updatedAt,
                createdAt: thread.createdAt,
                isPinned: thread.isPinned != 0,
                model: thread.model,
                status: status
            )
        }
        return TaskSnapshot(tasks: tasks, warning: warning)
    }

    private func query<T: Decodable>(database: String, sql: String) throws -> T {
        guard FileManager.default.fileExists(atPath: database) else {
            throw TaskStoreError.missingDatabase(database)
        }
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database, sql]
        process.standardOutput = output
        process.standardError = errorOutput
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "sqlite3 exited with status \(process.terminationStatus)"
                throw TaskStoreError.queryFailed(database, detail)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw TaskStoreError.invalidResponse(database)
            }
        } catch {
            if error is TaskStoreError { throw error }
            throw TaskStoreError.queryFailed(database, error.localizedDescription)
        }
    }
}

enum CanvasError: LocalizedError {
    case missingChatGPT
    case quitTimedOut
    case rendererTimedOut
    case missingResources
    case invalidDevToolsResponse
    case devToolsTimedOut
    case injectionFailed(String)
    case removalFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingChatGPT:
            return "ChatGPT was not found in /Applications."
        case .quitTimedOut:
            return "ChatGPT did not close. Finish any open prompt and quit it manually, then try again."
        case .rendererTimedOut:
            return "ChatGPT reopened, but the local Codex renderer did not become available."
        case .missingResources:
            return "The dashboard adapter resources are missing from the application bundle."
        case .invalidDevToolsResponse:
            return "The Codex renderer returned an invalid debugging response."
        case .devToolsTimedOut:
            return "The Codex renderer did not respond to the dashboard request."
        case .injectionFailed(let message):
            return "Dashboard injection failed: \(message)"
        case .removalFailed(let message):
            return "Dashboard removal failed: \(message)"
        }
    }
}

func withDevToolsTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: duration)
            throw CanvasError.devToolsTimedOut
        }

        guard let result = try await group.next() else {
            throw CanvasError.invalidDevToolsResponse
        }
        group.cancelAll()
        return result
    }
}

struct CanvasAdapter: Sendable {
    let version: String
    let expression: String

    static func load(bundle: Bundle = .main) throws -> CanvasAdapter {
        guard
            let scriptURL = bundle.url(forResource: "canvas", withExtension: "js", subdirectory: "Adapter"),
            let cssURL = bundle.url(forResource: "canvas", withExtension: "css", subdirectory: "Adapter")
        else {
            throw CanvasError.missingResources
        }

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let stylesheet = try String(contentsOf: cssURL, encoding: .utf8)
        let digest = SHA256.hash(data: Data((script + stylesheet).utf8))
        let version = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let cssData = try JSONSerialization.data(withJSONObject: stylesheet, options: .fragmentsAllowed)
        guard let encodedCSS = String(data: cssData, encoding: .utf8) else {
            throw CanvasError.missingResources
        }
        let expression = """
        (() => {
          const CANVAS_VERSION = \(String(reflecting: version));
          const CANVAS_CSS = \(encodedCSS);
          \(script)
        })()
        """
        return CanvasAdapter(version: version, expression: expression)
    }
}

actor DevToolsClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        session = URLSession(configuration: configuration)
    }

    func targets() async -> [DevToolsTarget] {
        guard let endpoint = URL(string: "http://\(devToolsHost):\(devToolsPort)/json/list") else { return [] }
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

    func evaluate(_ expression: String, in target: DevToolsTarget) async throws -> Bool {
        try await withDevToolsTimeout(.seconds(4)) { [self] in
            try await evaluateWithoutTimeout(expression, in: target)
        }
    }

    private func evaluateWithoutTimeout(_ expression: String, in target: DevToolsTarget) async throws -> Bool {
        guard
            let address = target.webSocketDebuggerUrl,
            let webSocketURL = URL(string: address)
        else {
            throw CanvasError.invalidDevToolsResponse
        }

        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        return try await withTaskCancellationHandler {
            try await send(["id": 1, "method": "Page.enable"], through: task)
            try await send([
                "id": 2,
                "method": "Page.setBypassCSP",
                "params": ["enabled": true],
            ], through: task)
            try await send([
                "id": 3,
                "method": "Runtime.evaluate",
                "params": [
                    "expression": expression,
                    "returnByValue": true,
                    "awaitPromise": true,
                ],
            ], through: task)

            while true {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    payload["id"] as? Int == 3
                else { continue }

                if let error = payload["error"] as? [String: Any] {
                    throw CanvasError.injectionFailed(error["message"] as? String ?? "Unknown DevTools error")
                }
                if let result = payload["result"] as? [String: Any], result["exceptionDetails"] != nil {
                    throw CanvasError.injectionFailed("The adapter raised an exception in the renderer.")
                }
                let result = payload["result"] as? [String: Any]
                let remote = result?["result"] as? [String: Any]
                guard let value = remote?["value"] as? Bool else {
                    throw CanvasError.invalidDevToolsResponse
                }
                return value
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func send(_ object: [String: Any], through task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CanvasError.invalidDevToolsResponse
        }
        try await task.send(.string(string))
    }
}

@MainActor
final class CanvasModel: ObservableObject {
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var isInjected = false
    @Published var isBusy = false
    @Published var statusTitle = "Checking Codex…"
    @Published var statusDetail = "Looking for the local ChatGPT application."
    @Published var lastError: String?
    @Published var dataWarning: String?
    @Published var tasks: [DashboardTask] = []

    private let devTools = DevToolsClient()
    private let taskStore = TaskStore()
    private var adapter: CanvasAdapter?
    private var shouldMaintainInjection = true
    private var injectionGeneration = 0
    private var activeInjectionAttempts = 0
    private var monitor: Task<Void, Never>?

    init() {
        do {
            adapter = try CanvasAdapter.load()
        } catch {
            lastError = error.localizedDescription
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit { monitor?.cancel() }

    func refresh() async {
        do {
            let snapshot = try await taskStore.load()
            tasks = snapshot.tasks
            dataWarning = snapshot.warning
        } catch {
            dataWarning = "Task data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
        }

        guard !isBusy else { return }
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleIdentifier).isEmpty
        let targets = await devTools.targets()
        guard !isBusy else { return }
        isConnected = !targets.isEmpty

        if shouldMaintainInjection, isConnected {
            await inject(showProgress: false)
            return
        }

        // Keep an actionable lifecycle error visible until a user action or a
        // successful maintenance attempt clears it.
        if lastError != nil { return }

        if isInjected && isConnected {
            statusTitle = "Dashboard is live"
            statusDetail = "\(tasks.filter { $0.status == "running" }.count) running · \(tasks.filter { $0.status == "recent" }.count) recently active"
        } else if isConnected {
            statusTitle = "Codex is connected"
            statusDetail = "The local renderer is ready for the task dashboard."
        } else if isRunning {
            isInjected = false
            statusTitle = "Codex is running normally"
            statusDetail = "Restart it through Dashboard once to add the task view."
        } else {
            isInjected = false
            statusTitle = "Codex is closed"
            statusDetail = "Dashboard can launch it with the local bridge enabled."
        }
    }

    func restartAndConnect() async {
        guard !isBusy else { return }
        isBusy = true
        injectionGeneration &+= 1
        shouldMaintainInjection = false
        lastError = nil
        statusTitle = "Restarting Codex…"
        statusDetail = "Waiting for the application to close cleanly."
        defer { isBusy = false }

        do {
            guard FileManager.default.isExecutableFile(atPath: chatGPTExecutable) else {
                throw CanvasError.missingChatGPT
            }
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleIdentifier)
            applications.forEach { $0.terminate() }

            let quitDeadline = ContinuousClock.now + .seconds(12)
            while !NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleIdentifier).isEmpty {
                guard ContinuousClock.now < quitDeadline else { throw CanvasError.quitTimedOut }
                try await Task.sleep(for: .milliseconds(250))
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: chatGPTExecutable)
            process.arguments = [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=\(devToolsPort)",
                "--remote-allow-origins=http://localhost",
            ]
            try process.run()

            statusTitle = "Connecting to Codex…"
            statusDetail = "Waiting for the renderer to become available."
            let rendererDeadline = ContinuousClock.now + .seconds(18)
            while await devTools.targets().isEmpty {
                guard ContinuousClock.now < rendererDeadline else { throw CanvasError.rendererTimedOut }
                try await Task.sleep(for: .milliseconds(350))
            }

            injectionGeneration &+= 1
            shouldMaintainInjection = true
            await inject(showProgress: false)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            statusTitle = "Dashboard needs attention"
            statusDetail = "Review the message below and try again."
        }
    }

    func inject(showProgress: Bool = true) async {
        guard !isBusy || !showProgress else { return }
        guard shouldMaintainInjection else { return }
        let generation = injectionGeneration
        activeInjectionAttempts += 1
        defer { activeInjectionAttempts -= 1 }
        if showProgress { isBusy = true }
        defer { if showProgress { isBusy = false } }
        lastError = nil

        do {
            guard let adapter else { throw CanvasError.missingResources }
            let targets = await devTools.targets()
            guard generation == injectionGeneration, shouldMaintainInjection else { return }
            guard !targets.isEmpty else { throw CanvasError.rendererTimedOut }
            var applied = 0
            for target in targets {
                guard generation == injectionGeneration, shouldMaintainInjection else { return }
                if try await devTools.evaluate(adapter.expression, in: target) { applied += 1 }
            }
            guard generation == injectionGeneration, shouldMaintainInjection else { return }
            isConnected = true
            isInjected = applied > 0
            guard isInjected else {
                throw CanvasError.injectionFailed("The adapter did not mount in the Codex renderer.")
            }
            await updateDashboard(targets: targets)
            guard generation == injectionGeneration, shouldMaintainInjection else { return }
            statusTitle = "Dashboard is live"
            statusDetail = "\(tasks.filter { $0.status == "running" }.count) running · \(tasks.filter { $0.status == "recent" }.count) recently active"
        } catch {
            guard generation == injectionGeneration, shouldMaintainInjection else { return }
            isInjected = false
            lastError = error.localizedDescription
            statusTitle = "Dashboard needs attention"
            statusDetail = "Codex is connected, but the dashboard could not be loaded."
        }
    }

    func remove() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        injectionGeneration &+= 1
        shouldMaintainInjection = false
        lastError = nil

        while activeInjectionAttempts > 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let targets = await devTools.targets()
        guard !targets.isEmpty else {
            isConnected = false
            isInjected = false
            statusTitle = "Dashboard is disconnected"
            statusDetail = "The ChatGPT application bundle remains unchanged."
            return
        }

        do {
            for target in targets {
                let removed = try await devTools.evaluate(
                    "(() => { window.__codexDashboard?.destroy?.(); return typeof window.__codexDashboard === 'undefined'; })()",
                    in: target
                )
                guard removed else {
                    throw CanvasError.removalFailed("The renderer still reports an active dashboard.")
                }
            }
            isInjected = false
            statusTitle = "Dashboard removed"
            statusDetail = "The ChatGPT application bundle remains unchanged."
        } catch {
            isInjected = true
            lastError = error.localizedDescription
            statusTitle = "Dashboard needs attention"
            statusDetail = "Automatic maintenance is off, but removal could not be confirmed."
        }
    }

    func openCanvas() async {
        let targets = await devTools.targets()
        for target in targets {
            _ = try? await devTools.evaluate(
                "(() => { window.__codexDashboard?.open?.(); return true; })()",
                in: target
            )
        }
    }

    private func updateDashboard(targets: [DevToolsTarget]) async {
        guard let data = try? JSONEncoder().encode(tasks),
              let json = String(data: data, encoding: .utf8) else { return }
        let expression = "(() => { window.__codexDashboard?.update?.(\(json)); return true; })()"
        for target in targets {
            _ = try? await devTools.evaluate(expression, in: target)
        }
    }
}

struct StatusCard: View {
    @ObservedObject var model: CanvasModel

    private var statusColor: Color {
        if model.isInjected { return Color(red: 0.45, green: 0.94, blue: 0.61) }
        if model.isRunning { return Color(red: 0.96, green: 0.77, blue: 0.42) }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.35), radius: 5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(model.statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Refresh") { Task { await model.refresh() } }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }
}

struct ContentView: View {
    @StateObject private var model = CanvasModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 0.72, green: 1.0, blue: 0.79))
                    Text("C")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.06, green: 0.09, blue: 0.07))
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCAL UI LAYER")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Codex Dashboard")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .tracking(-1.2)
                    Text("Active tasks, built into your local Codex app.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            StatusCard(model: model)

            HStack(spacing: 10) {
                Button {
                    Task { await model.restartAndConnect() }
                } label: {
                    Text("Restart Codex & Enable Dashboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.05, green: 0.08, blue: 0.06))
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity)
                        .background(
                            Color(red: 0.64, green: 0.95, blue: 0.70),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)

                Button("Open Dashboard") { Task { await model.openCanvas() } }
                    .disabled(!model.isInjected || model.isBusy)

                Button("Remove") { Task { await model.remove() } }
                    .disabled(!model.isConnected || model.isBusy)
            }
            .controlSize(.large)

            if model.lastError != nil || model.dataWarning != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = model.lastError { Text(error) }
                    if let warning = model.dataWarning { Text(warning) }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1.0, green: 0.60, blue: 0.60))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("The dashboard reads local Codex task metadata and activity logs. Restarting closes Codex briefly; the signed application bundle is never modified.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 620, height: 410, alignment: .topLeading)
        .background(
            RadialGradient(
                colors: [Color.green.opacity(0.075), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 380
            )
        )
        .task { await model.refresh() }
    }
}

@main
struct CodexCanvasApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
