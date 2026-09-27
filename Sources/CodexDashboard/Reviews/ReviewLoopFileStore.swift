import Foundation

@MainActor
final class ReviewLoopFileStore: ReviewLoopStoring {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> [ReviewLoop] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Preserve the saved loop when upgrading from the single-loop format.
        if try JSONSerialization.jsonObject(with: data) is [String: Any] {
            return [try decoder.decode(ReviewLoop.self, from: data)]
        }
        return try decoder.decode([ReviewLoop].self, from: data)
    }

    func save(_ loops: [ReviewLoop]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(loops).write(to: url, options: .atomic)
    }
}
