import Foundation

protocol ThreadCatalogProviding: Sendable {
    func loadCatalog(
        codexLaunchDate: Date?,
        requiredThreadIDs: Set<String>
    ) async throws -> ThreadCatalog
}

enum ThreadCatalogError: LocalizedError {
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

actor CodexThreadCatalogProvider: ThreadCatalogProviding {
    static let defaultLoadedThreadLimit = 500
    static let requiredColumnNames: Set<String> = [
        "id", "name", "title", "preview", "cwd", "created_at", "is_pinned",
        "model", "rollout_path", "archived", "recency_at_ms",
    ]

    private struct StoredThread: Decodable, Sendable {
        let id: String
        let title: String
        let preview: String
        let projectPath: String
        let pinnedValue: Int
        let model: String?
        let totalCount: Int
        let rolloutPath: String
        let recencyAtMilliseconds: Int64
    }

    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

    private struct DatabaseSignature: Equatable {
        let database: FileSignature
        let writeAheadLog: FileSignature?
    }

    private let stateDatabaseURL: URL
    private let loadedThreadLimit: Int
    private var rolloutActivityReader = RolloutActivityReader()
    private var cachedDatabaseSignature: DatabaseSignature?
    private var cachedLaunchMilliseconds: Int64?
    private var cachedRequiredThreadIDs: Set<String>?
    private var cachedStoredThreads: [StoredThread]?
    private let subprocessTimeout: TimeInterval

    init(
        stateDatabaseURL: URL = CodexConfiguration.stateDatabaseURL,
        loadedThreadLimit: Int = CodexThreadCatalogProvider.defaultLoadedThreadLimit,
        subprocessTimeout: TimeInterval = 3
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.loadedThreadLimit = max(1, loadedThreadLimit)
        self.subprocessTimeout = subprocessTimeout
    }

    func loadCatalog(
        codexLaunchDate: Date?,
        requiredThreadIDs: Set<String>
    ) async throws -> ThreadCatalog {
        let launchMilliseconds = codexLaunchDate.map {
            Int64($0.timeIntervalSince1970 * 1_000)
        }
        let currentLaunchPredicate = launchMilliseconds.map { "recency_at_ms >= \($0)" } ?? "0"
        let requiredThreadPredicate = requiredThreadIDs.isEmpty
            ? "0"
            : "id IN (\(requiredThreadIDs.sorted().map(Self.sqlStringLiteral).joined(separator: ", ")))"
        let threadSQL = """
        WITH recent_threads AS (
            SELECT id
            FROM threads
            WHERE archived = 0 AND preview <> ''
            ORDER BY recency_at_ms DESC
            LIMIT \(loadedThreadLimit)
        )
        SELECT id,
               COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), 'Untitled thread') AS title,
               preview,
               cwd AS projectPath,
               is_pinned AS pinnedValue,
               model,
               rollout_path AS rolloutPath,
               recency_at_ms AS recencyAtMilliseconds,
               (
                   SELECT COUNT(*)
                   FROM threads AS countedThreads
                   WHERE countedThreads.archived = 0 AND countedThreads.preview <> ''
               ) AS totalCount
        FROM threads
        WHERE archived = 0
          AND preview <> ''
          AND (id IN (SELECT id FROM recent_threads) OR \(requiredThreadPredicate) OR \(currentLaunchPredicate))
        ORDER BY recency_at_ms DESC
        """
        let databaseSignature = try signature(for: stateDatabaseURL)
        let threads: [StoredThread]
        if databaseSignature == cachedDatabaseSignature,
           requiredThreadIDs == cachedRequiredThreadIDs,
           launchMilliseconds == cachedLaunchMilliseconds,
           let cachedStoredThreads {
            threads = cachedStoredThreads
        } else {
            threads = try await query(databaseURL: stateDatabaseURL, sql: threadSQL)
            cachedDatabaseSignature = databaseSignature
            cachedRequiredThreadIDs = requiredThreadIDs
            cachedLaunchMilliseconds = launchMilliseconds
            cachedStoredThreads = threads
        }
        let activityPaths: Set<String> = Set(threads.lazy.compactMap { thread -> String? in
            guard
                let launchMilliseconds,
                thread.recencyAtMilliseconds >= launchMilliseconds
            else { return nil }
            return thread.rolloutPath
        })
        rolloutActivityReader.retainCache(for: activityPaths)
        let threadSummaries = threads.map { thread in
            let directoryName = URL(fileURLWithPath: thread.projectPath).lastPathComponent
            let latestLifecycleEvent = activityPaths.contains(thread.rolloutPath)
                ? rolloutActivityReader.latestEvent(
                    at: thread.rolloutPath,
                    codexLaunchDate: codexLaunchDate
                )
                : nil
            let runState: ThreadRunState = latestLifecycleEvent?.kind == .started ? .running : .idle
            return ThreadSummary(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                projectName: directoryName.isEmpty ? thread.projectPath : directoryName,
                projectPath: thread.projectPath,
                recencyEpochMillis: thread.recencyAtMilliseconds,
                isPinned: thread.pinnedValue != 0,
                model: thread.model,
                runState: runState,
                latestLifecycleEvent: latestLifecycleEvent,
                workingTreeStatus: .notRepository
            )
        }.sorted { left, right in
            if left.recencyEpochMillis == right.recencyEpochMillis {
                return left.id < right.id
            }
            return left.recencyEpochMillis > right.recencyEpochMillis
        }
        return ThreadCatalog(
            threads: threadSummaries,
            totalThreadCount: threads.first?.totalCount ?? 0
        )
    }

    private static func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func signature(for databaseURL: URL) throws -> DatabaseSignature {
        guard let database = fileSignature(at: databaseURL) else {
            throw ThreadCatalogError.missingDatabase(databaseURL)
        }
        return DatabaseSignature(
            database: database,
            writeAheadLog: fileSignature(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        )
    }

    private func fileSignature(at url: URL) -> FileSignature? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        return FileSignature(size: size, modifiedAt: modifiedAt)
    }

    private func query(databaseURL: URL, sql: String) async throws -> [StoredThread] {
        do {
            let result = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-readonly", "-json", databaseURL.path, sql],
                timeout: subprocessTimeout
            )
            guard result.terminationStatus == 0 else {
                let message = String(data: result.standardError, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "sqlite3 exited with status \(result.terminationStatus)"
                throw ThreadCatalogError.queryFailed(databaseURL, detail)
            }
            if result.standardOutput.isEmpty { return [] }
            do {
                return try JSONDecoder().decode([StoredThread].self, from: result.standardOutput)
            } catch {
                throw ThreadCatalogError.invalidResponse(databaseURL)
            }
        } catch {
            if error is ThreadCatalogError { throw error }
            throw ThreadCatalogError.queryFailed(databaseURL, error.localizedDescription)
        }
    }
}
