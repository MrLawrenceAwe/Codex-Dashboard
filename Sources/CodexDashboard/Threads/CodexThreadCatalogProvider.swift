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
        "model", "rollout_path", "archived", "recency_at_ms", "project_id",
    ]

    private struct StoredThread: Decodable, Equatable, Sendable {
        let id: String
        let title: String
        let preview: String
        let projectID: String?
        let checkoutPath: String
        let pinnedValue: Int
        let model: String?
        let totalCount: Int
        let rolloutPath: String
        let recencyAtMilliseconds: Int64
    }

    private struct ProjectRoot: Decodable, Sendable {
        let id: String
        let name: String
        let path: String
    }

    private func registeredRoot(for thread: StoredThread, in roots: [ProjectRoot]) -> ProjectRoot? {
        let cwd = FileSystemPath.canonicalPath(thread.checkoutPath)
        let assigned = roots.filter { $0.id == thread.projectID }
        let candidates = thread.projectID == nil ? roots : assigned
        return candidates.filter { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count } ?? assigned.first
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
    private var cachedProjectRoots: [ProjectRoot] = []
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
        // Inspect empty-preview tasks touched during this launch; only running
        // ones are kept in the visible catalog below.
        let candidateThreadPredicate = "(preview <> '' OR \(currentLaunchPredicate))"
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
               project_id AS projectID,
               cwd AS checkoutPath,
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
          AND \(candidateThreadPredicate)
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
            let roots: [ProjectRoot] = try await query(databaseURL: stateDatabaseURL, sql: """
                SELECT projects.id, projects.name, project_roots.path
                FROM projects JOIN project_roots ON project_roots.project_id = projects.id
                ORDER BY projects.position, project_roots.position
                """)
            cachedProjectRoots = roots.map { ProjectRoot(id: $0.id, name: $0.name, path: FileSystemPath.canonicalPath($0.path)) }
            cachedDatabaseSignature = databaseSignature
            cachedRequiredThreadIDs = requiredThreadIDs
            cachedLaunchMilliseconds = launchMilliseconds
            cachedStoredThreads = threads
        }
        let activityPaths = Set(threads.map(\.rolloutPath))
        rolloutActivityReader.retainCache(for: activityPaths)
        // Any loaded task can be resumed or hit a usage limit without a database
        // write. The reader checks file signatures and only parses changed rollouts.
        let candidates: [ThreadSummary] = threads.map { thread in
            let root = registeredRoot(for: thread, in: cachedProjectRoots)
            let recordedEvent = rolloutActivityReader.latestRecordedEvent(at: thread.rolloutPath)
            let isCurrentEvent = recordedEvent.map { event in
                codexLaunchDate.map { event.timestamp >= $0 } ?? false
            } ?? false
            let usageLimitWasContinued = recordedEvent.map { event in
                guard event.kind == .usageLimitReached else { return false }
                return thread.recencyAtMilliseconds > Int64(event.timestamp.timeIntervalSince1970 * 1_000)
            } ?? false
            let latestLifecycleEvent = isCurrentEvent || (
                recordedEvent?.kind == .usageLimitReached && !usageLimitWasContinued
            )
                ? recordedEvent
                : nil
            let runState: ThreadRunState = isCurrentEvent && recordedEvent?.kind == .started
                ? .running
                : .idle
            var summary = ThreadSummary(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                projectName: root?.name ?? "Other chats",
                checkoutPath: thread.checkoutPath,
                recencyEpochMillis: thread.recencyAtMilliseconds,
                isPinned: thread.pinnedValue != 0,
                model: thread.model,
                runState: runState,
                latestLifecycleEvent: latestLifecycleEvent,
                projectGitStatus: .notRepository
            )
            summary.projectID = root?.id
            if let root {
                let cwd = FileSystemPath.canonicalPath(thread.checkoutPath)
                // Worktree chats can be assigned to a project outside its saved root.
                summary.projectGroupPath = cwd == root.path || cwd.hasPrefix(root.path + "/") ? root.path : cwd
            }
            return summary
        }
        let threadSummaries = candidates.filter { $0.preview != "" || $0.runState == .running }.sorted { left, right in
            if left.recencyEpochMillis == right.recencyEpochMillis {
                return left.id < right.id
            }
            return left.recencyEpochMillis > right.recencyEpochMillis
        }
        return ThreadCatalog(
            threads: threadSummaries,
            totalThreadCount: (threads.first?.totalCount ?? 0)
                + threadSummaries.count { $0.preview.isEmpty && $0.runState == .running }
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

    private func query<Row: Decodable>(databaseURL: URL, sql: String) async throws -> [Row] {
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
                return try JSONDecoder().decode([Row].self, from: result.standardOutput)
            } catch {
                throw ThreadCatalogError.invalidResponse(databaseURL)
            }
        } catch {
            if error is ThreadCatalogError { throw error }
            throw ThreadCatalogError.queryFailed(databaseURL, error.localizedDescription)
        }
    }
}
