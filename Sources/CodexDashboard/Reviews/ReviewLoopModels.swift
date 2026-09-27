import Foundation

struct ReviewModel: Codable, Sendable {
    let model: String
    let displayName: String
    let efforts: [String]
}

struct ReviewModelSelection: Codable, Equatable, Sendable {
    let model: String
    let effort: String?
}

struct ReviewProject: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
}

enum ReviewLoopPhase: String, Codable, Sendable {
    case waiting, running, paused, completed, stopped, blocked
}

struct ReviewRound: Codable, Equatable, Sendable {
    let number: Int
    let baseCommit: String
    var threadID: String?
    var reviewTurnID: String?
    var fixTurnID: String?
    var fixRequested = false
    var review: ReviewReport?
    var result: ReviewRoundResult?
}

struct ReviewFinding: Codable, Equatable, Sendable {
    enum Priority: String, Codable, CaseIterable, Sendable {
        case p0 = "P0", p1 = "P1", p2 = "P2", p3 = "P3"
        var rank: Int { Self.allCases.firstIndex(of: self)! }
        var label: String { self == .p0 ? "P0" : "\(rawValue)+" }
        var included: [String] { Self.allCases.filter { $0.rank <= rank }.map(\.rawValue) }
    }
    let priority: Priority
    let title: String
    let body: String
}

struct ReviewReport: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case reviewed, blocked }
    let outcome: Outcome
    let findings: [ReviewFinding]
    let summary: String
    func qualifyingFindings(upTo limit: ReviewFinding.Priority) -> [ReviewFinding] {
        findings.filter { $0.priority.rank <= limit.rank }
    }
}

enum ReviewTurnKind { case review(ReviewFinding.Priority), fix }

struct ReviewRoundResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case clean, fixed, blocked }
    let outcome: Outcome
    let findings: Int
    let commit: String
    let summary: String
}

struct ReviewLoop: Codable, Equatable, Sendable {
    let id: UUID
    let startActionID: String
    let project: ReviewProject
    let instructions: String
    let maxRounds: Int
    var selection: ReviewModelSelection? = nil
    var priorityLimit: ReviewFinding.Priority = .p2
    var phase: ReviewLoopPhase = .waiting
    var pauseRequested = false
    var branch: String?
    var expectedCommit: String?
    var rounds: [ReviewRound] = []
    var message = "Waiting for the project to be idle."
}

struct ReviewLoopAction: Codable, Sendable {
    let id: String
    let kind: String
    let projectID: String?
    let instructions: String?
    let maxRounds: Int?
    let loopID: UUID?
    var selection: ReviewModelSelection? = nil
    var priorityLimit: ReviewFinding.Priority? = nil
}

struct ReviewLoopSnapshot: Codable, Sendable {
    let projects: [ReviewProject]
    let models: [ReviewModel]
    let loop: ReviewLoop?
    let progress: ReviewLoopProgress?
    let error: String?
    let acknowledgedActionID: String?
}

struct ReviewPromptPreview: Codable, Sendable {
    let title: String
    let text: String
    let note: String
}

struct ReviewLoopProgress: Codable, Sendable {
    let step: String
    let currentLabel: String
    let current: ReviewPromptPreview?
    let upcoming: ReviewPromptPreview?
    let nextMessage: String
    let threadID: String?
}

struct ReviewRepositoryState: Equatable, Sendable {
    let root: String
    let branch: String
    let commit: String
    let clean: Bool
}

struct ReviewTurnState: Sendable {
    let id: String
    let status: String
    let finalMessage: String?
}

struct ReviewThreadState: Sendable {
    let cwd: String
    let turns: [ReviewTurnState]
}

struct ReviewLoopError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
protocol ReviewLoopDriving {
    func projects() async throws -> [ReviewProject]
    func repository(at path: String) async throws -> ReviewRepositoryState
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool
    func createThread(project: ReviewProject, title: String) async throws -> String
    func startTurn(threadID: String, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?) async throws -> String
    func readThread(_ threadID: String) async throws -> ReviewThreadState
}

@MainActor
protocol ReviewLoopStoring {
    func load() throws -> ReviewLoop?
    func save(_ loop: ReviewLoop) throws
}

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
