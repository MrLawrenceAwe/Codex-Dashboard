import Foundation

struct RolloutStatus: Equatable, Sendable {
    let activity: ThreadActivity
    let lastFinalResponseAtUnixSeconds: Int64?
}

struct RolloutStatusReader {
    private enum ActivityEvent {
        case started
        case ended
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            let phase: String?
        }

        let timestamp: String?
        let payload: Payload?
    }

    private struct CacheEntry {
        let size: UInt64
        let modifiedAt: Date
        let endsWithNewline: Bool
        let status: RolloutStatus
    }

    private var cache: [String: CacheEntry] = [:]

    mutating func load(
        at path: String,
        activeApplicationLaunchDate: Date?
    ) -> RolloutStatus {
        let fileURL = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return RolloutStatus(activity: .idle, lastFinalResponseAtUnixSeconds: nil)
        }

        let status: RolloutStatus
        if let cached = cache[path], cached.size == size, cached.modifiedAt == modifiedAt {
            status = cached.status
        } else if
            let cached = cache[path],
            cached.size < size,
            cached.endsWithNewline
        {
            let appendedStatus = read(
                in: fileURL,
                lowerBound: cached.size,
                fallbackActivity: cached.status.activity
            )
            status = RolloutStatus(
                activity: appendedStatus.activity,
                lastFinalResponseAtUnixSeconds: appendedStatus.lastFinalResponseAtUnixSeconds
                    ?? cached.status.lastFinalResponseAtUnixSeconds
            )
        } else {
            status = read(in: fileURL)
        }
        cache[path] = CacheEntry(
            size: size,
            modifiedAt: modifiedAt,
            endsWithNewline: fileEndsWithNewline(fileURL, size: size),
            status: status
        )

        guard let activeApplicationLaunchDate, modifiedAt >= activeApplicationLaunchDate else {
            return RolloutStatus(
                activity: .idle,
                lastFinalResponseAtUnixSeconds: status.lastFinalResponseAtUnixSeconds
            )
        }
        return status
    }

    private func read(
        in fileURL: URL,
        lowerBound: UInt64 = 0,
        fallbackActivity: ThreadActivity = .idle
    ) -> RolloutStatus {
        let markers: [(event: ActivityEvent, data: Data)] = [
            (.started, Data(#""type":"task_started""#.utf8)),
            (.ended, Data(#""type":"task_complete""#.utf8)),
            (.ended, Data(#""type":"turn_aborted""#.utf8)),
        ]
        let finalResponseMarker = Data(#""phase":"final_answer""#.utf8)
        let timestampMarker = Data(#""timestamp":""#.utf8)
        let chunkSize: UInt64 = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return RolloutStatus(activity: .idle, lastFinalResponseAtUnixSeconds: nil)
        }
        defer { try? handle.close() }
        guard var cursor = try? handle.seekToEnd() else {
            return RolloutStatus(activity: .idle, lastFinalResponseAtUnixSeconds: nil)
        }
        var laterLineFragment = Data()
        var lastEvent: ActivityEvent?
        var lastFinalResponseAtUnixSeconds: Int64?

        while cursor > lowerBound {
            let bytesToRead = min(chunkSize, cursor - lowerBound)
            cursor -= bytesToRead
            do {
                try handle.seek(toOffset: cursor)
                guard var data = try handle.read(upToCount: Int(bytesToRead)) else { break }
                data.append(laterLineFragment)

                var lineEnd = data.endIndex
                while let newline = data[..<lineEnd].lastIndex(of: UInt8(ascii: "\n")) {
                    let lineStart = data.index(after: newline)
                    inspect(
                        data[lineStart..<lineEnd],
                        markers: markers,
                        finalResponseMarker: finalResponseMarker,
                        timestampMarker: timestampMarker,
                        lastEvent: &lastEvent,
                        lastFinalResponseAtUnixSeconds: &lastFinalResponseAtUnixSeconds
                    )
                    lineEnd = newline
                    if lastEvent != nil, lastFinalResponseAtUnixSeconds != nil { break }
                }
                if lastEvent != nil, lastFinalResponseAtUnixSeconds != nil { break }

                if cursor == lowerBound {
                    inspect(
                        data[..<lineEnd],
                        markers: markers,
                        finalResponseMarker: finalResponseMarker,
                        timestampMarker: timestampMarker,
                        lastEvent: &lastEvent,
                        lastFinalResponseAtUnixSeconds: &lastFinalResponseAtUnixSeconds
                    )
                } else {
                    laterLineFragment = Data(data[..<lineEnd])
                }
            } catch {
                break
            }
        }
        return RolloutStatus(
            activity: lastEvent.map { $0 == .started ? .running : .idle }
                ?? fallbackActivity,
            lastFinalResponseAtUnixSeconds: lastFinalResponseAtUnixSeconds
        )
    }

    private func fileEndsWithNewline(_ fileURL: URL, size: UInt64) -> Bool {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: size - 1)
            return try handle.read(upToCount: 1)?.first == UInt8(ascii: "\n")
        } catch {
            return false
        }
    }

    private func inspect(
        _ line: Data.SubSequence,
        markers: [(event: ActivityEvent, data: Data)],
        finalResponseMarker: Data,
        timestampMarker: Data,
        lastEvent: inout ActivityEvent?,
        lastFinalResponseAtUnixSeconds: inout Int64?
    ) {
        if lastEvent == nil {
            let matches = markers.compactMap { marker -> (ActivityEvent, Data.Index)? in
                guard let range = line.range(of: marker.data, options: .backwards) else {
                    return nil
                }
                return (marker.event, range.lowerBound)
            }
            lastEvent = matches.max { $0.1 < $1.1 }?.0
        }

        guard
            lastFinalResponseAtUnixSeconds == nil,
            line.range(of: finalResponseMarker) != nil,
            line.range(of: timestampMarker) != nil,
            let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line)),
            envelope.payload?.phase == "final_answer",
            let timestamp = envelope.timestamp,
            let date = try? Date(timestamp, strategy: .iso8601)
        else { return }
        lastFinalResponseAtUnixSeconds = Int64(date.timeIntervalSince1970)
    }
}
