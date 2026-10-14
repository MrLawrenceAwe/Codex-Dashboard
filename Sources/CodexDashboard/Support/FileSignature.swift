import Foundation

/// File metadata used to invalidate cached reads and detect changes.
struct FileSignature: Equatable, Sendable {
    let size: UInt64
    let modifiedAt: Date

    static func read(at url: URL) throws -> FileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return FileSignature(size: size, modifiedAt: modifiedAt)
    }
}
