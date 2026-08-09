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
    private struct RolloutActivity: Sendable {
        let status: ThreadActivityStatus
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
    private var rolloutActivityCache: [String: (size: UInt64, modifiedAt: Date, activity: RolloutActivity)] = [:]
    private let subprocessTimeout: TimeInterval

    init(
        stateDatabaseURL: URL = AppConfiguration.stateDatabaseURL,
        subprocessTimeout: TimeInterval = 3
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.subprocessTimeout = subprocessTimeout
    }

    func loadSnapshot(
        gitStatuses: [String: WorkspaceGitStatus]
    ) throws -> ThreadSnapshot {
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
        let dashboardThreads = threads.map { thread in
            let directoryName = URL(fileURLWithPath: thread.cwd).lastPathComponent
            let activity = rolloutActivity(at: thread.rolloutPath)
            return DashboardThread(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                workspace: directoryName.isEmpty ? thread.cwd : directoryName,
                workspacePath: thread.cwd,
                updatedAt: thread.updatedAt,
                isPinned: thread.isPinned != 0,
                model: thread.model,
                status: activity.status,
                gitStatus: gitStatuses[thread.cwd] ?? .notRepository
            )
        }
        return ThreadSnapshot(
            threads: dashboardThreads,
            totalThreadCount: threads.first?.totalCount ?? 0
        )
    }

    func loadGitStatuses(
        at workspacePaths: Set<String>
    ) async -> [String: WorkspaceGitStatus] {
        let timeout = subprocessTimeout
        return await withTaskGroup(
            of: (String, WorkspaceGitStatus).self,
            returning: [String: WorkspaceGitStatus].self
        ) { group in
            for path in workspacePaths {
                group.addTask {
                    (path, Self.workspaceGitStatus(at: path, timeout: timeout))
                }
            }
            var statuses: [String: WorkspaceGitStatus] = [:]
            for await (path, status) in group {
                statuses[path] = status
            }
            return statuses
        }
    }

    private func rolloutActivity(at path: String) -> RolloutActivity {
        let fileURL = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return RolloutActivity(status: .idle)
        }
        if let cached = rolloutActivityCache[path],
           cached.size == size,
           cached.modifiedAt == modifiedAt {
            return cached.activity
        }

        let activity = lifecycleActivity(in: fileURL)
        rolloutActivityCache[path] = (size, modifiedAt, activity)
        return activity
    }

    private enum LifecycleEvent {
        case started
        case completed
        case aborted
    }

    private func lifecycleActivity(in fileURL: URL) -> RolloutActivity {
        let markers: [(event: LifecycleEvent, data: Data)] = [
            (.started, Data(#""type":"task_started""#.utf8)),
            (.completed, Data(#""type":"task_complete""#.utf8)),
            (.aborted, Data(#""type":"turn_aborted""#.utf8)),
        ]
        let overlapSize = (markers.map(\.data.count).max() ?? 1) - 1
        let chunkSize: UInt64 = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return RolloutActivity(status: .idle)
        }
        defer { try? handle.close() }
        guard var cursor = try? handle.seekToEnd() else {
            return RolloutActivity(status: .idle)
        }
        var laterOverlap = Data()
        var lastEvent: LifecycleEvent?

        while cursor > 0 {
            let bytesToRead = min(chunkSize, cursor)
            cursor -= bytesToRead
            do {
                try handle.seek(toOffset: cursor)
                guard var data = try handle.read(upToCount: Int(bytesToRead)) else { break }
                data.append(laterOverlap)

                let matches = markers.compactMap { marker -> (LifecycleEvent, Data.Index)? in
                    guard let range = data.range(of: marker.data, options: .backwards) else {
                        return nil
                    }
                    return (marker.event, range.lowerBound)
                }
                if lastEvent == nil {
                    lastEvent = matches.max { $0.1 < $1.1 }?.0
                }
                if lastEvent != nil { break }

                laterOverlap = Data(data.prefix(overlapSize))
            } catch {
                break
            }
        }
        return RolloutActivity(status: lastEvent == .started ? .running : .idle)
    }

    nonisolated private static func workspaceGitStatus(
        at path: String,
        timeout: TimeInterval
    ) -> WorkspaceGitStatus {
        let status: WorkspaceGitStatus
        do {
            let result = try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "status", "--porcelain=v1", "--untracked-files=normal"],
                timeout: timeout
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
