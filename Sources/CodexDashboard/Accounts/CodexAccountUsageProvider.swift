import Darwin
import Foundation

protocol AccountUsageProviding: Sendable {
    func usage() async throws -> CodexAccountUsage
    func usage(using credential: Data) async throws -> SavedAccountUsageResult
    func reset() async
}

struct SavedAccountUsageResult: Equatable, Sendable {
    let usage: CodexAccountUsage
    let credential: Data
}

enum CodexAccountUsageError: LocalizedError {
    case malformedResponse
    case server(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Codex returned invalid account usage data."
        case .server(let message):
            return "Codex could not read account usage: \(message)"
        case .unavailable:
            return "Codex account usage is unavailable."
        }
    }
}

actor AppServerUsageProvider: AccountUsageProviding {
    private let executableURL: URL
    private let codexHomeURL: URL
    private let timeout: Duration
    private var session: CodexAppServerSession?
    private var inFlightUsage: Task<CodexAccountUsage, Error>?
    private var inFlightSavedAccountUsage: Task<SavedAccountUsageResult, Error>?

    init(
        executableURL: URL = CodexConfiguration.codexExecutableURL,
        codexHomeURL: URL = CodexConfiguration.codexDirectory,
        timeout: Duration = .seconds(12)
    ) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
        self.timeout = timeout
    }

    func usage() async throws -> CodexAccountUsage {
        if let inFlightUsage { return try await inFlightUsage.value }
        let task = Task { try await self.fetchUsage() }
        inFlightUsage = task
        defer { inFlightUsage = nil }
        return try await task.value
    }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        guard inFlightSavedAccountUsage == nil else {
            throw CodexAccountUsageError.unavailable
        }
        let task = Task { try await self.fetchUsage(using: credential) }
        inFlightSavedAccountUsage = task
        defer { inFlightSavedAccountUsage = nil }
        return try await task.value
    }

    func reset() {
        inFlightUsage?.cancel()
        inFlightUsage = nil
        inFlightSavedAccountUsage?.cancel()
        inFlightSavedAccountUsage = nil
        session?.terminate()
        session = nil
    }

    private func fetchUsage() async throws -> CodexAccountUsage {
        let activeSession: CodexAppServerSession
        if let session, session.isRunning {
            activeSession = session
        } else {
            activeSession = try await startSession(codexHomeURL: codexHomeURL)
            session = activeSession
        }

        do {
            let responseData = try await activeSession.request(
                id: 2,
                method: "account/rateLimits/read",
                timeout: timeout
            )
            let response = try JSONDecoder().decode(RateLimitsResponse.self, from: responseData)
            return response.result.accountUsage
        } catch {
            if session === activeSession { session = nil }
            activeSession.terminate()
            throw error
        }
    }

    private func fetchUsage(using credential: Data) async throws -> SavedAccountUsageResult {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory.appendingPathComponent(
            "CodexDashboardUsage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let credentialFile = ActiveCodexCredentialFile(
            url: temporaryHome.appendingPathComponent("auth.json"),
            fileManager: fileManager
        )
        try credentialFile.write(credential)
        let isolatedSession = try await startSession(codexHomeURL: temporaryHome)
        defer { isolatedSession.terminate() }

        let responseData = try await isolatedSession.request(
            id: 2,
            method: "account/rateLimits/read",
            timeout: timeout
        )
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: responseData)
        isolatedSession.terminate()
        return SavedAccountUsageResult(
            usage: response.result.accountUsage,
            credential: try credentialFile.read() ?? credential
        )
    }

    private func startSession(codexHomeURL: URL) async throws -> CodexAppServerSession {
        let session = try CodexAppServerSession(
            executableURL: executableURL,
            codexHomeURL: codexHomeURL
        )
        do {
            _ = try await session.request(
                id: 1,
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex-dashboard",
                        "title": "Codex Dashboard",
                        "version": "1",
                    ],
                ],
                timeout: timeout
            )
            try session.notify(method: "initialized")
            return session
        } catch {
            session.terminate()
            throw error
        }
    }
}

private final class CodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let lifecycleLock = NSLock()
    private var terminated = false
    private var readBuffer = Data()

    var isRunning: Bool {
        lifecycleLock.withLock { !terminated && process.isRunning }
    }

    init(executableURL: URL, codexHomeURL: URL) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        process.environment = environment

        try process.run()
        try outputPipe.fileHandleForWriting.close()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
    }

    deinit {
        terminate()
    }

    func request(
        id: Int,
        method: String,
        params: [String: Any]? = nil,
        timeout: Duration
    ) async throws -> Data {
        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }
        try write(payload)
        return try await response(id: id, timeout: timeout)
    }

    func notify(method: String) throws {
        try write(["method": method])
    }

    func terminate() {
        let shouldTerminate = lifecycleLock.withLock {
            guard !terminated else { return false }
            terminated = true
            return true
        }
        guard shouldTerminate else { return }
        try? inputHandle.close()
        if process.isRunning {
            process.terminate()
            let process = process
            let identifier = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                if process.isRunning { Darwin.kill(identifier, SIGKILL) }
            }
        }
    }

    private func write(_ payload: [String: Any]) throws {
        guard isRunning else { throw CodexAccountUsageError.unavailable }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func response(id: Int, timeout: Duration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self, returning: Data.self) { group in
                group.addTask { try self.readResponse(id: id) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    self.terminate()
                    throw CodexAccountUsageError.unavailable
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else {
                    throw CodexAccountUsageError.unavailable
                }
                return response
            }
        } onCancel: {
            self.terminate()
        }
    }

    private func readResponse(id: Int) throws -> Data {
        while true {
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                guard (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw CodexAccountUsageError.server(
                        error["message"] as? String ?? "Unknown app-server error"
                    )
                }
                guard object["result"] != nil else {
                    throw CodexAccountUsageError.malformedResponse
                }
                return line
            }

            let chunk = outputHandle.availableData
            guard !chunk.isEmpty else {
                throw CodexAccountUsageError.unavailable
            }
            readBuffer.append(chunk)
        }
    }
}

private struct RateLimitsResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let rateLimits: Snapshot
        let rateLimitResetCredits: ResetCredits?

        var accountUsage: CodexAccountUsage {
            rateLimits.accountUsage(bankedResets: rateLimitResetCredits?.summary)
        }
    }
}

private struct Snapshot: Decodable {
    let primary: Window?
    let secondary: Window?

    func accountUsage(bankedResets: CodexBankedResetSummary?) -> CodexAccountUsage {
        let windows = [primary, secondary].compactMap { $0 }
        return CodexAccountUsage(
            fiveHour: windows.first { $0.windowDurationMins == 300 }?.usageWindow
                ?? primary?.usageWindow,
            weekly: windows.first { $0.windowDurationMins == 10_080 }?.usageWindow
                ?? secondary?.usageWindow,
            bankedResets: bankedResets
        )
    }
}

private struct ResetCredits: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]?

    var summary: CodexBankedResetSummary {
        CodexBankedResetSummary(
            availableCount: max(0, availableCount),
            nextExpiration: credits?
                .filter { $0.status == "available" }
                .compactMap(\.expiresAt)
                .min()
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct ResetCredit: Decodable {
    let status: String
    let expiresAt: Int64?
}

private struct Window: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var usageWindow: CodexUsageWindow {
        CodexUsageWindow(
            usedPercent: min(100, max(0, usedPercent)),
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
