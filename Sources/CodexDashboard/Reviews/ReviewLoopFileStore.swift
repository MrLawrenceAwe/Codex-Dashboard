import Foundation

@MainActor
final class ReviewLoopFileStore: ReviewLoopStoring {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> ReviewLoop? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ReviewLoop.self, from: Data(contentsOf: url))
    }

    func save(_ loop: ReviewLoop) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(loop).write(to: url, options: .atomic)
    }
}
