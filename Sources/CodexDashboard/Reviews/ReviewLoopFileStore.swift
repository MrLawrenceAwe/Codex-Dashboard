import Foundation

@MainActor
final class ReviewLoopFileStore: ReviewLoopStoring {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> [ReviewLoop] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try ReviewLoopDocumentMigration.decode(Data(contentsOf: url))
    }

    func save(_ loops: [ReviewLoop]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let document = ReviewLoopDocumentMigration.Document(
            version: ReviewLoopDocumentMigration.Document.currentVersion,
            loops: loops
        )
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
