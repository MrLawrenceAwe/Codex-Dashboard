import Foundation

protocol ThreadSnapshotLoading: Sendable {
    func loadSnapshot(
        gitWorkingTreeStatuses: [String: GitWorkingTreeStatus],
        activeApplicationLaunchDate: Date?
    ) async throws -> ThreadSnapshot
}

enum ThreadRepositoryError: LocalizedError {
    case missingDatabase(URL)
    case queryFailed(URL, String)
    case invalidResponse(URL)

    var errorDescription: String? {
        switch self {
        case .missingDatabase(let databaseURL):
            return "The Codex database is missing: \(databaseURL.path)"
        case .queryFailed(let databaseURL, let message):
            return "Could not read \(databaseURL.path): \(message)"
        case .invalidResponse(let databaseURL):
            return "Codex returned unreadable data from \(databaseURL.path)."
        }
    }
}

actor CodexThreadRepository: ThreadSnapshotLoading {
    private struct StoredThread: Decodable, Sendable {
        let id: String
        let title: String
        let preview: String
        let workspacePath: String
        let createdAtUnixSeconds: Int64
        let pinnedValue: Int
        let model: String?
        let totalCount: Int
        let rolloutPath: String
    }

    private let stateDatabaseURL: URL
    private var rolloutStatusReader = RolloutStatusReader()
    private let subprocessTimeout: TimeInterval

    init(
        stateDatabaseURL: URL = CodexConfiguration.stateDatabaseURL,
        subprocessTimeout: TimeInterval = 3
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.subprocessTimeout = subprocessTimeout
    }

    func loadSnapshot(
        gitWorkingTreeStatuses: [String: GitWorkingTreeStatus],
        activeApplicationLaunchDate: Date?
    ) async throws -> ThreadSnapshot {
        let threadSQL = """
        SELECT id,
               COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), 'Untitled thread') AS title,
               preview,
               cwd AS workspacePath,
               created_at AS createdAtUnixSeconds,
               is_pinned AS pinnedValue,
               model,
               rollout_path AS rolloutPath,
               COUNT(*) OVER () AS totalCount
        FROM threads
        WHERE archived = 0 AND preview <> ''
        ORDER BY updated_at DESC
        LIMIT 60;
        """
        let threads: [StoredThread] = try query(databaseURL: stateDatabaseURL, sql: threadSQL)
        let dashboardThreads = threads.map { thread in
            let directoryName = URL(fileURLWithPath: thread.workspacePath).lastPathComponent
            let rolloutStatus = rolloutStatusReader.load(
                at: thread.rolloutPath,
                activeApplicationLaunchDate: activeApplicationLaunchDate
            )
            return DashboardThread(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                workspaceName: directoryName.isEmpty ? thread.workspacePath : directoryName,
                workspacePath: thread.workspacePath,
                recencyTimestamp: rolloutStatus.lastFinalResponseAtUnixSeconds
                    ?? thread.createdAtUnixSeconds,
                isPinned: thread.pinnedValue != 0,
                model: thread.model,
                activity: rolloutStatus.activity,
                gitWorkingTreeStatus: gitWorkingTreeStatuses[thread.workspacePath] ?? .notRepository
            )
        }.sorted { left, right in
            if left.recencyTimestamp == right.recencyTimestamp {
                return left.id < right.id
            }
            return left.recencyTimestamp > right.recencyTimestamp
        }
        return ThreadSnapshot(
            threads: dashboardThreads,
            availableThreadCount: threads.first?.totalCount ?? 0
        )
    }

    private func query<T: Decodable>(databaseURL: URL, sql: String) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ThreadRepositoryError.missingDatabase(databaseURL)
        }
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-readonly", "-json", databaseURL.path, sql],
                timeout: subprocessTimeout
            )
            guard result.terminationStatus == 0 else {
                let message = String(data: result.standardError, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "sqlite3 exited with status \(result.terminationStatus)"
                throw ThreadRepositoryError.queryFailed(databaseURL, detail)
            }
            do {
                return try JSONDecoder().decode(T.self, from: result.standardOutput)
            } catch {
                throw ThreadRepositoryError.invalidResponse(databaseURL)
            }
        } catch {
            if error is ThreadRepositoryError { throw error }
            throw ThreadRepositoryError.queryFailed(databaseURL, error.localizedDescription)
        }
    }
}
