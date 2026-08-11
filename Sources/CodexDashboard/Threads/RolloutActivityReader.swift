import Foundation

struct ThreadActivity: Equatable, Sendable {
    let runState: ThreadRunState
    let lastFinalResponseAtUnixSeconds: Int64?
}

struct RolloutActivityReader {
    static let startedEventType = "task_started"
    static let endedEventTypes = ["task_complete", "turn_aborted"]
    static let finalResponsePhase = "final_answer"
    static let lifecycleEventTypes = [startedEventType] + endedEventTypes

    private enum RunEvent {
        case started
        case completed
        case aborted

        var runState: ThreadRunState {
            self == .started ? .running : .idle
        }

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
        let status: ThreadActivity
    }

    private var cache: [String: CacheEntry] = [:]

    var cachedEntryCount: Int { cache.count }

    mutating func retainCache(for paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    mutating func load(
        at path: String,
        codexLaunchDate: Date?
    ) -> ThreadActivity {
        let fileURL = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return ThreadActivity(
                runState: .idle,
                lastFinalResponseAtUnixSeconds: nil
            )
        }

        let cached = cache[path]
        let status: ThreadActivity
        let endsWithNewline: Bool
        if let cached, cached.size == size, cached.modifiedAt == modifiedAt {
            status = cached.status
            endsWithNewline = cached.endsWithNewline
        } else if
            let cached,
            cached.size < size,
            cached.endsWithNewline
        {
            let appendedStatus = read(
                in: fileURL,
                lowerBound: cached.size,
                fallbackRunState: cached.status.runState
            )
            status = ThreadActivity(
                runState: appendedStatus.runState,
                lastFinalResponseAtUnixSeconds: appendedStatus.lastFinalResponseAtUnixSeconds
                    ?? cached.status.lastFinalResponseAtUnixSeconds
            )
            endsWithNewline = fileEndsWithNewline(fileURL, size: size)
        } else {
            status = read(in: fileURL)
            endsWithNewline = fileEndsWithNewline(fileURL, size: size)
        }
        cache[path] = CacheEntry(
            size: size,
            modifiedAt: modifiedAt,
            endsWithNewline: endsWithNewline,
            status: status
        )

        guard let codexLaunchDate, modifiedAt >= codexLaunchDate else {
            return ThreadActivity(
                runState: .idle,
                lastFinalResponseAtUnixSeconds: status.lastFinalResponseAtUnixSeconds
            )
        }
        return status
    }

    private func read(
        in fileURL: URL,
        lowerBound: UInt64 = 0,
        fallbackRunState: ThreadRunState = .idle
    ) -> ThreadActivity {
        let markers = [
            (RunEvent.started, Self.startedEventType),
            (RunEvent.completed, "task_complete"),
            (RunEvent.aborted, "turn_aborted"),
        ]
        let encodedMarkers = markers.map { (event: $0.0, data: Data(#""type":"\#($0.1)""#.utf8)) }
        let finalResponseMarker = Data(#""phase":"\#(Self.finalResponsePhase)""#.utf8)
        let timestampMarker = Data(#""timestamp":""#.utf8)
        let chunkSize: UInt64 = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ThreadActivity(
                runState: .idle,
                lastFinalResponseAtUnixSeconds: nil
            )
        }
        defer { try? handle.close() }
        guard var cursor = try? handle.seekToEnd() else {
            return ThreadActivity(
                runState: .idle,
                lastFinalResponseAtUnixSeconds: nil
            )
        }
        var laterLineFragment = Data()
        var lastEvent: RunEvent?
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
                        markers: encodedMarkers,
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
                        markers: encodedMarkers,
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
        return ThreadActivity(
            runState: lastEvent?.runState ?? fallbackRunState,
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
        markers: [(event: RunEvent, data: Data)],
        finalResponseMarker: Data,
        timestampMarker: Data,
        lastEvent: inout RunEvent?,
        lastFinalResponseAtUnixSeconds: inout Int64?
    ) {
        if lastEvent == nil {
            let matches = markers.compactMap { marker -> (RunEvent, Data.Index)? in
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
            envelope.payload?.phase == Self.finalResponsePhase,
            let timestamp = envelope.timestamp,
            let date = try? Date(timestamp, strategy: .iso8601)
        else { return }
        lastFinalResponseAtUnixSeconds = Int64(date.timeIntervalSince1970)
    }
}
