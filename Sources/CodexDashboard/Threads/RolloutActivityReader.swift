import Foundation

struct RolloutActivityReader {
    static let startedEventType = "task_started"
    static let endedEventTypes = ["task_complete", "turn_aborted"]
    static let finalResponsePhase = "final_answer"
    static let lifecycleEventTypes = [startedEventType] + endedEventTypes

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Failure: Decodable {
                let codexErrorInfo: String?

                private enum CodingKeys: String, CodingKey {
                    case codexErrorInfo = "codex_error_info"
                }
            }

            let type: String?
            let error: Failure?
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct CacheEntry {
        let size: UInt64
        let modifiedAt: Date
        let endsWithNewline: Bool
        let event: ThreadLifecycleEvent?
    }

    private var cache: [String: CacheEntry] = [:]

    var cachedEntryCount: Int { cache.count }

    mutating func retainCache(for paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    mutating func load(
        at path: String,
        codexLaunchDate: Date?
    ) -> ThreadRunState {
        let fileURL = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return .idle
        }

        let cached = cache[path]
        let event: ThreadLifecycleEvent?
        let endsWithNewline: Bool
        if let cached, cached.size == size, cached.modifiedAt == modifiedAt {
            event = cached.event
            endsWithNewline = cached.endsWithNewline
        } else if
            let cached,
            cached.size < size,
            cached.endsWithNewline
        {
            event = read(in: fileURL, lowerBound: cached.size) ?? cached.event
            endsWithNewline = fileEndsWithNewline(fileURL, size: size)
        } else {
            event = read(in: fileURL)
            endsWithNewline = fileEndsWithNewline(fileURL, size: size)
        }
        cache[path] = CacheEntry(
            size: size,
            modifiedAt: modifiedAt,
            endsWithNewline: endsWithNewline,
            event: event
        )

        guard
            let codexLaunchDate,
            let event,
            event.timestamp >= codexLaunchDate
        else { return .idle }
        return event.kind == .started ? .running : .idle
    }

    mutating func latestEvent(
        at path: String,
        codexLaunchDate: Date?
    ) -> ThreadLifecycleEvent? {
        _ = load(at: path, codexLaunchDate: codexLaunchDate)
        guard
            let codexLaunchDate,
            let event = cache[path]?.event,
            event.timestamp >= codexLaunchDate
        else { return nil }
        return event
    }

    mutating func latestRecordedEvent(at path: String) -> ThreadLifecycleEvent? {
        _ = load(at: path, codexLaunchDate: nil)
        return cache[path]?.event
    }

    private func read(
        in fileURL: URL,
        lowerBound: UInt64 = 0
    ) -> ThreadLifecycleEvent? {
        let markers = [
            (ThreadLifecycleEventKind.started, Self.startedEventType),
            (ThreadLifecycleEventKind.completed, "task_complete"),
            (ThreadLifecycleEventKind.aborted, "turn_aborted"),
        ]
        let encodedMarkers = markers.map { (event: $0.0, data: Data(#""type":"\#($0.1)""#.utf8)) }
        let chunkSize: UInt64 = 64 * 1_024
        let maximumEventLineSize = 256 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard var cursor = try? handle.seekToEnd() else {
            return nil
        }
        var laterLineFragment = Data()
        var discardingOversizedLine = false

        while cursor > lowerBound {
            let bytesToRead = min(chunkSize, cursor - lowerBound)
            cursor -= bytesToRead
            do {
                try handle.seek(toOffset: cursor)
                guard let data = try handle.read(upToCount: Int(bytesToRead)) else { break }

                var lineEnd = data.endIndex
                var isLatestSegment = true
                while let newline = data[..<lineEnd].lastIndex(of: UInt8(ascii: "\n")) {
                    let lineStart = data.index(after: newline)
                    if isLatestSegment {
                        if !discardingOversizedLine {
                            var line = Data(data[lineStart..<lineEnd])
                            if line.count + laterLineFragment.count <= maximumEventLineSize {
                                line.append(laterLineFragment)
                                if let event = inspect(line, markers: encodedMarkers) { return event }
                            }
                        }
                        discardingOversizedLine = false
                        laterLineFragment.removeAll(keepingCapacity: true)
                        isLatestSegment = false
                    } else if lineEnd - lineStart <= maximumEventLineSize,
                              let event = inspect(data[lineStart..<lineEnd], markers: encodedMarkers) {
                        return event
                    }
                    lineEnd = newline
                }

                if cursor == lowerBound {
                    guard !discardingOversizedLine else { return nil }
                    var line = Data(data[..<lineEnd])
                    guard line.count + laterLineFragment.count <= maximumEventLineSize else {
                        return nil
                    }
                    line.append(laterLineFragment)
                    return inspect(line, markers: encodedMarkers)
                } else if isLatestSegment {
                    if !discardingOversizedLine,
                       data.count + laterLineFragment.count <= maximumEventLineSize {
                        laterLineFragment.insert(contentsOf: data, at: 0)
                    } else {
                        laterLineFragment.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                    }
                } else {
                    laterLineFragment = Data(data[..<lineEnd])
                    discardingOversizedLine = laterLineFragment.count > maximumEventLineSize
                    if discardingOversizedLine {
                        laterLineFragment.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                break
            }
        }
        return nil
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
        _ line: some DataProtocol,
        markers: [(event: ThreadLifecycleEventKind, data: Data)]
    ) -> ThreadLifecycleEvent? {
        let lineData = Data(line)
        guard
            markers.contains(where: { lineData.range(of: $0.data) != nil }),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: lineData),
            envelope.type == "event_msg",
            let payloadType = envelope.payload?.type,
            let timestamp = envelope.timestamp,
            let date = try? Date(
                timestamp,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: timestamp.contains("."))
            )
        else { return nil }
        let kind: ThreadLifecycleEventKind
        switch payloadType {
        case Self.startedEventType: kind = .started
        case "task_complete":
            kind = envelope.payload?.error?.codexErrorInfo == "usage_limit_exceeded"
                ? .forcedHalt
                : .completed
        case "turn_aborted": kind = .aborted
        default: return nil
        }
        return ThreadLifecycleEvent(kind: kind, timestamp: date)
    }
}
