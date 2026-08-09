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
        let workspacePath: String
        let createdAtUnixSeconds: Int64
        let pinnedValue: Int
        let model: String?
        let totalCount: Int
        let rolloutPath: String
    }

    private let stateDatabaseURL: URL
    private struct RolloutStatus: Sendable {
        let activity: ThreadActivity
        let lastFinalResponseAtUnixSeconds: Int64?
    }

    private var rolloutCache: [String: (size: UInt64, modifiedAt: Date, status: RolloutStatus)] = [:]
    private let subprocessTimeout: TimeInterval

    init(
        stateDatabaseURL: URL = CodexConfiguration.stateDatabaseURL,
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
            let rolloutStatus = rolloutStatus(at: thread.rolloutPath)
            return DashboardThread(
                id: thread.id,
                title: thread.title,
                preview: thread.preview,
                workspace: directoryName.isEmpty ? thread.workspacePath : directoryName,
                workspacePath: thread.workspacePath,
                updatedAtUnixSeconds: rolloutStatus.lastFinalResponseAtUnixSeconds
                    ?? thread.createdAtUnixSeconds,
                isPinned: thread.pinnedValue != 0,
                model: thread.model,
                activity: rolloutStatus.activity,
                gitStatus: gitStatuses[thread.workspacePath] ?? .notRepository
            )
        }.sorted { left, right in
            if left.updatedAtUnixSeconds == right.updatedAtUnixSeconds {
                return left.id < right.id
            }
            return left.updatedAtUnixSeconds > right.updatedAtUnixSeconds
        }
        return ThreadSnapshot(
            threads: dashboardThreads,
            totalThreadCount: threads.first?.totalCount ?? 0
        )
    }

    private func rolloutStatus(at path: String) -> RolloutStatus {
        let fileURL = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return RolloutStatus(activity: .idle, lastFinalResponseAtUnixSeconds: nil)
        }
        if let cached = rolloutCache[path],
           cached.size == size,
           cached.modifiedAt == modifiedAt {
            return cached.status
        }

        let status = readRolloutStatus(in: fileURL)
        rolloutCache[path] = (size, modifiedAt, status)
        return status
    }

    private enum ActivityEvent {
        case started
        case ended
    }

    private func readRolloutStatus(in fileURL: URL) -> RolloutStatus {
        let markers: [(event: ActivityEvent, data: Data)] = [
            (.started, Data(#""type":"task_started""#.utf8)),
            (.ended, Data(#""type":"task_complete""#.utf8)),
            (.ended, Data(#""type":"turn_aborted""#.utf8)),
        ]
        let finalResponseMarker = Data(#""phase":"final_answer""#.utf8)
        let timestampMarker = Data(#""timestamp":""#.utf8)
        let overlapSize = max(markers.map(\.data.count).max() ?? 1, finalResponseMarker.count) - 1
        let chunkSize: UInt64 = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return RolloutStatus(activity: .idle, lastFinalResponseAtUnixSeconds: nil)
        }
        defer { try? handle.close() }
        guard var cursor = try? handle.seekToEnd() else {
            return RolloutStatus(activity: .idle, lastFinalResponseAtUnixSeconds: nil)
        }
        var laterOverlap = Data()
        var lastEvent: ActivityEvent?
        var lastFinalResponseAtUnixSeconds: Int64?

        while cursor > 0 {
            let bytesToRead = min(chunkSize, cursor)
            cursor -= bytesToRead
            do {
                try handle.seek(toOffset: cursor)
                guard var data = try handle.read(upToCount: Int(bytesToRead)) else { break }
                data.append(laterOverlap)

                let matches = markers.compactMap { marker -> (ActivityEvent, Data.Index)? in
                    guard let range = data.range(of: marker.data, options: .backwards) else {
                        return nil
                    }
                    return (marker.event, range.lowerBound)
                }
                if lastEvent == nil {
                    lastEvent = matches.max { $0.1 < $1.1 }?.0
                }
                if lastFinalResponseAtUnixSeconds == nil,
                   let finalRange = data.range(of: finalResponseMarker, options: .backwards) {
                    let lineStart = data[..<finalRange.lowerBound].lastIndex(of: UInt8(ascii: "\n"))
                        .map { data.index(after: $0) } ?? data.startIndex
                    let lineEnd = data[finalRange.upperBound...].firstIndex(of: UInt8(ascii: "\n"))
                        ?? data.endIndex
                    guard let timestampRange = data[lineStart..<lineEnd].range(of: timestampMarker)
                    else {
                        laterOverlap = Data(data.prefix(overlapSize))
                        continue
                    }
                    let valueStart = timestampRange.upperBound
                    if let valueEnd = data[valueStart...].firstIndex(of: UInt8(ascii: "\"")),
                       let timestamp = String(data: data[valueStart..<valueEnd], encoding: .utf8),
                       let date = ISO8601DateFormatter().date(from: timestamp) {
                        lastFinalResponseAtUnixSeconds = Int64(date.timeIntervalSince1970)
                    }
                }
                if lastEvent != nil, lastFinalResponseAtUnixSeconds != nil { break }

                laterOverlap = Data(data.prefix(overlapSize))
            } catch {
                break
            }
        }
        return RolloutStatus(
            activity: lastEvent == .started ? .running : .idle,
            lastFinalResponseAtUnixSeconds: lastFinalResponseAtUnixSeconds
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
