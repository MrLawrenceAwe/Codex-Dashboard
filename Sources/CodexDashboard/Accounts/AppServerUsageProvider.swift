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
        try await fetchUsage()
    }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        try await fetchUsage(using: credential)
    }

    func reset() {
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
