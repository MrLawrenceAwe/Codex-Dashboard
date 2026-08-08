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
    private struct CachedGitStatus: Sendable {
        let value: WorkspaceGitStatus
        let checkedAt: Date
    }

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
    private var gitStatusCache: [String: CachedGitStatus] = [:]
    private let gitStatusCacheLifetime: TimeInterval = 10

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
        let workspacePaths = Set(threads.map(\.cwd))
        var gitStatuses: [String: WorkspaceGitStatus] = [:]
        for path in workspacePaths {
            gitStatuses[path] = workspaceGitStatus(at: path)
        }
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
                workspacePath: thread.cwd,
                updatedAt: thread.updatedAt,
                isPinned: thread.isPinned != 0,
                model: thread.model,
                status: status,
                gitStatus: gitStatuses[thread.cwd] ?? .notRepository
            )
        }
        return ThreadSnapshot(
            threads: dashboardThreads,
            totalThreadCount: threads.first?.totalCount ?? 0,
            warning: warning
        )
    }

    private func workspaceGitStatus(at path: String) -> WorkspaceGitStatus {
        let checkedAt = Date()
        if let cached = gitStatusCache[path],
           checkedAt.timeIntervalSince(cached.checkedAt) < gitStatusCacheLifetime {
            return cached.value
        }

        guard containsGitMetadata(at: path) else {
            let status: WorkspaceGitStatus = .notRepository
            gitStatusCache[path] = CachedGitStatus(value: status, checkedAt: checkedAt)
            return status
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "status", "--porcelain=v1", "--untracked-files=normal"]
        process.standardOutput = output
        process.standardError = errorOutput

        let status: WorkspaceGitStatus
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            _ = errorOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                status = .notRepository
            } else if data.isEmpty {
                status = .clean
            } else {
                status = .modified
            }
        } catch {
            status = .notRepository
        }
        gitStatusCache[path] = CachedGitStatus(value: status, checkedAt: checkedAt)
        return status
    }

    private func containsGitMetadata(at path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false }
            directory = parent
        }
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
