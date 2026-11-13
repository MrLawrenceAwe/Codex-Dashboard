import Foundation

enum ProjectEditedFileReader {
    private struct Record: Decodable {
        struct Payload: Decodable {
            struct Item: Decodable {
                struct Change: Decodable {
                    let type: String
                    let move_path: String?
                }

                let type: String
                let status: String?
                let changes: [String: Change]?
            }

            let type: String
            let item: Item?
        }

        let type: String
        let payload: Payload
    }

    static func paths(in rollout: URL, root: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: rollout)
        defer { try? handle.close() }
        let maximumRecordBytes = 8 * 1024 * 1024
        var fragment = Data()
        var oversized = false
        var lastEdit: [String: Int] = [:]
        var order = 0
        let marker = Data("FileChange".utf8)

        func inspect(_ data: Data) {
            guard data.range(of: marker) != nil,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.type == "event_msg", record.payload.type == "item_completed",
                  let item = record.payload.item, item.type == "FileChange",
                  item.status == "completed", let changes = item.changes else { return }
            for path in changes.keys.sorted() {
                guard let change = changes[path] else { continue }
                if change.type == "delete" || change.move_path != nil {
                    if let oldPath = relativePath(path, root: root) {
                        lastEdit.removeValue(forKey: oldPath)
                    }
                }
                guard change.type == "add" || change.type == "update",
                      let relative = relativePath(change.move_path ?? path, root: root) else { continue }
                order += 1
                lastEdit[relative] = order
            }
        }

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 10) {
                if !oversized && fragment.count + newline - start <= maximumRecordBytes {
                    fragment.append(chunk[start..<newline])
                    inspect(fragment)
                }
                fragment.removeAll(keepingCapacity: true)
                oversized = false
                start = newline + 1
            }
            if !oversized && fragment.count + chunk.endIndex - start <= maximumRecordBytes {
                fragment.append(chunk[start...])
            } else {
                oversized = true
                fragment.removeAll(keepingCapacity: true)
            }
        }
        if !oversized && !fragment.isEmpty { inspect(fragment) }
        return lastEdit.keys.sorted { lastEdit[$0, default: 0] > lastEdit[$1, default: 0] }
    }

    private static func relativePath(_ path: String, root: URL) -> String? {
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let canonical = FileSystemPath.canonicalPath(url.path)
        guard canonical != root.path, FileSystemPath.contains(canonical, in: root.path) else { return nil }
        return String(canonical.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }
}
