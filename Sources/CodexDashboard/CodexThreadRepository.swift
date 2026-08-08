import Foundation

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

actor CodexThreadRepository {
    private struct StoredThread: Decodable, Sendable {
        let id: String
        let title: String
        let preview: String
        let cwd: String
        let updatedAt: Int64
        let isPinned: Int
        let model: String?
        let totalCount: Int
    }

    private struct ThreadActivity: Decodable, Sendable {
        let threadId: String
        let lastActivity: Int64
    }

    private let stateDatabaseURL: URL
    private let activityDatabaseURL: URL

    init(
        stateDatabaseURL: URL = AppConfiguration.stateDatabaseURL,
        activityDatabaseURL: URL = AppConfiguration.activityDatabaseURL
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.activityDatabaseURL = activityDatabaseURL
    }

    func loadSnapshot() throws -> ThreadSnapshot {
        let threadSQL = """
        SELECT id,
               COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), 'Untitled thread') AS title,
               preview,
               cwd,
               updated_at AS updatedAt,
               is_pinned AS isPinned,
               model,
               COUNT(*) OVER () AS totalCount
        FROM threads
        WHERE archived = 0 AND preview <> ''
        ORDER BY updated_at DESC
        LIMIT 60;
        """
        let activitySQL = """
        SELECT thread_id AS threadId, MAX(ts) AS lastActivity
        FROM logs
        WHERE thread_id IS NOT NULL AND thread_id <> ''
          AND ts >= CAST(strftime('%s','now') AS INTEGER) - 120
        GROUP BY thread_id;
        """
        let threads: [StoredThread] = try query(databaseURL: stateDatabaseURL, sql: threadSQL)
        let activity: [ThreadActivity]
        let warning: String?
        do {
            activity = try query(databaseURL: activityDatabaseURL, sql: activitySQL)
            warning = nil
        } catch {
            activity = []
            warning = "Thread activity is temporarily unavailable. \(error.localizedDescription)"
        }

        let latestActivity = Dictionary(uniqueKeysWithValues: activity.map { ($0.threadId, $0.lastActivity) })
        let now = Int64(Date().timeIntervalSince1970)
        let dashboardThreads = threads.map { thread in
            let lastLogTime = latestActivity[thread.id] ?? 0
            let status: ThreadActivityStatus
            if now - lastLogTime <= 12 {
                status = .running
            } else {
                status = .idle
            }
            let directoryName = URL(fileURLWithPath: thread.cwd).lastPathComponent
            return DashboardThread(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                workspace: directoryName.isEmpty ? thread.cwd : directoryName,
                updatedAt: thread.updatedAt,
                isPinned: thread.isPinned != 0,
                model: thread.model,
                status: status
            )
        }
        return ThreadSnapshot(
            threads: dashboardThreads,
            totalThreadCount: threads.first?.totalCount ?? 0,
            warning: warning
        )
    }

    private func query<T: Decodable>(databaseURL: URL, sql: String) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ThreadRepositoryError.missingDatabase(databaseURL)
        }
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, sql]
        process.standardOutput = output
        process.standardError = errorOutput
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "sqlite3 exited with status \(process.terminationStatus)"
                throw ThreadRepositoryError.queryFailed(databaseURL, detail)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw ThreadRepositoryError.invalidResponse(databaseURL)
            }
        } catch {
            if error is ThreadRepositoryError { throw error }
            throw ThreadRepositoryError.queryFailed(databaseURL, error.localizedDescription)
        }
    }
}
