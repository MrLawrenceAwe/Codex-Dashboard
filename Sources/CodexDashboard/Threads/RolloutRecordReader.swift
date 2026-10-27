import Foundation

// Cached, bounded-memory reverse JSONL scanning shared by lifecycle and question readers.
struct RolloutRecordReader<Record> {
    private struct CacheEntry {
        let signature: FileSignature
        let endsWithNewline: Bool
        let event: Record?
    }

    let inspect: (Data) -> Record?

    init(inspect: @escaping (Data) -> Record?) {
        self.inspect = inspect
    }

    private var cache: [String: CacheEntry] = [:]

    var cachedEntryCount: Int { cache.count }

    mutating func retainCache(for paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    mutating func latestRecordedEvent(at path: String) -> Record? {
        let fileURL = URL(fileURLWithPath: path)
        guard let signature = try? FileSignature.read(at: fileURL) else { return nil }

        let cached = cache[path]
        let event: Record?
        let endsWithNewline: Bool
        if let cached, cached.signature == signature {
            event = cached.event
            endsWithNewline = cached.endsWithNewline
        } else if
            let cached,
            cached.signature.size < signature.size,
            cached.endsWithNewline
        {
            event = read(in: fileURL, lowerBound: cached.signature.size) ?? cached.event
            endsWithNewline = fileEndsWithNewline(fileURL, size: signature.size)
        } else {
            event = read(in: fileURL)
            endsWithNewline = fileEndsWithNewline(fileURL, size: signature.size)
        }
        cache[path] = CacheEntry(
            signature: signature,
            endsWithNewline: endsWithNewline,
            event: event
        )

        return event
    }

    private func read(
        in fileURL: URL,
        lowerBound: UInt64 = 0
    ) -> Record? {
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
                                if let event = inspect(line) { return event }
                            }
                        }
                        discardingOversizedLine = false
                        laterLineFragment.removeAll(keepingCapacity: true)
                        isLatestSegment = false
                    } else if lineEnd - lineStart <= maximumEventLineSize,
                              let event = inspect(Data(data[lineStart..<lineEnd])) {
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
                    return inspect(line)
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

}
