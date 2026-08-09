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
        let rolloutPath: String
    }

    private let stateDatabaseURL: URL
    private var gitStatusCache: [String: CachedGitStatus] = [:]
    private var rolloutStatusCache: [String: (size: UInt64, modifiedAt: Date, status: ThreadActivityStatus)] = [:]
    private let gitStatusCacheLifetime: TimeInterval = 10
    private let subprocessTimeout: TimeInterval

    init(
        stateDatabaseURL: URL = AppConfiguration.stateDatabaseURL,
        subprocessTimeout: TimeInterval = 3
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.subprocessTimeout = subprocessTimeout
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
               rollout_path AS rolloutPath,
               COUNT(*) OVER () AS totalCount
        FROM threads
        WHERE archived = 0 AND preview <> ''
        ORDER BY updated_at DESC
        LIMIT 60;
        """
        let threads: [StoredThread] = try query(databaseURL: stateDatabaseURL, sql: threadSQL)
        let workspacePaths = Set(threads.map(\.cwd))
        var gitStatuses: [String: WorkspaceGitStatus] = [:]
        for path in workspacePaths {
            gitStatuses[path] = workspaceGitStatus(at: path)
        }
        let dashboardThreads = threads.map { thread in
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
                status: rolloutStatus(at: thread.rolloutPath),
                gitStatus: gitStatuses[thread.cwd] ?? .notRepository
            )
        }
        return ThreadSnapshot(
            threads: dashboardThreads,
            totalThreadCount: threads.first?.totalCount ?? 0
        )
    }

    private func rolloutStatus(at path: String) -> ThreadActivityStatus {
        let fileURL = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return .idle
        }
        if let cached = rolloutStatusCache[path],
           cached.size == size,
           cached.modifiedAt == modifiedAt {
            return cached.status
        }

        let status = lastLifecycleEvent(in: fileURL) == .started
            ? ThreadActivityStatus.running
            : ThreadActivityStatus.idle
        rolloutStatusCache[path] = (size, modifiedAt, status)
        return status
    }

    private enum LifecycleEvent {
        case started
        case completed
    }

    private func lastLifecycleEvent(in fileURL: URL) -> LifecycleEvent? {
        let startedMarker = Data(#""type":"task_started""#.utf8)
        let completedMarker = Data(#""type":"task_complete""#.utf8)
        let overlapSize = max(startedMarker.count, completedMarker.count) - 1
        let chunkSize: UInt64 = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard var cursor = try? handle.seekToEnd() else { return nil }
        var laterOverlap = Data()

        while cursor > 0 {
            let bytesToRead = min(chunkSize, cursor)
            cursor -= bytesToRead
            do {
                try handle.seek(toOffset: cursor)
                guard var data = try handle.read(upToCount: Int(bytesToRead)) else { return nil }
                data.append(laterOverlap)

                let startedRange = data.range(of: startedMarker, options: .backwards)
                let completedRange = data.range(of: completedMarker, options: .backwards)
                if let startedRange, let completedRange {
                    return startedRange.lowerBound > completedRange.lowerBound ? .started : .completed
                }
                if startedRange != nil { return .started }
                if completedRange != nil { return .completed }

                laterOverlap = Data(data.prefix(overlapSize))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func workspaceGitStatus(at path: String) -> WorkspaceGitStatus {
        let checkedAt = Date()
        if let cached = gitStatusCache[path],
           checkedAt.timeIntervalSince(cached.checkedAt) < gitStatusCacheLifetime {
            return cached.value
        }

        let status: WorkspaceGitStatus
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "status", "--porcelain=v1", "--untracked-files=normal"],
                timeout: subprocessTimeout
            )
            if result.terminationStatus != 0 {
                status = .notRepository
            } else if result.standardOutput.isEmpty {
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
