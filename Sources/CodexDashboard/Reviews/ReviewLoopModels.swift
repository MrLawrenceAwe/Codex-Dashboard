import Foundation

struct ReviewModel: Codable, Sendable {
    let modelID: String
    let displayName: String
    let supportedReasoningEfforts: [String]
}

struct ReviewModelSelection: Codable, Equatable, Sendable {
    let modelID: String
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case modelID, reasoningEffort
        case savedModelID = "model"
        case savedReasoningEffort = "effort"
    }

    init(modelID: String, reasoningEffort: String?) {
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
            ?? values.decode(String.self, forKey: .savedModelID)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
            ?? values.decodeIfPresent(String.self, forKey: .savedReasoningEffort)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(modelID, forKey: .modelID)
        try values.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }
}

enum ReviewSpeed: String, Codable, Sendable {
    case standard, fast
    var serviceTier: String { self == .fast ? "priority" : "default" }
}

struct ReviewProject: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
}

enum ReviewLoopPhase: String, Codable, Sendable {
    case waiting, running, paused, completed, limitReached, stopped, blocked
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
        var rangeLabel: String { self == .p0 ? "P0" : "P0–\(rawValue)" }
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
    let findingCount: Int
    let commit: String
    let summary: String

    private enum CodingKeys: String, CodingKey {
        case outcome, commit, summary
        case findingCount = "findings"
    }
}

struct ReviewLoop: Codable, Equatable, Sendable {
    let id: UUID
    let startActionID: String
    let project: ReviewProject
    let instructions: String
    let maxRounds: Int
    var selection: ReviewModelSelection? = nil
    var speed: ReviewSpeed = .standard
    var priorityLimit: ReviewFinding.Priority = .p2
    var phase: ReviewLoopPhase = .waiting
    var pauseRequested = false
    var branch: String?
    var checkoutRoot: String?
    var expectedCommit: String?
    var rounds: [ReviewRound] = []
    var message = "Waiting for the project to be idle."
}

extension ReviewLoop {
    private enum CodingKeys: String, CodingKey {
        case id, startActionID, project, instructions, maxRounds, selection, speed,
             priorityLimit, phase, pauseRequested, branch, checkoutRoot, expectedCommit, rounds, message
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        startActionID = try values.decode(String.self, forKey: .startActionID)
        project = try values.decode(ReviewProject.self, forKey: .project)
        instructions = try values.decode(String.self, forKey: .instructions)
        maxRounds = try values.decode(Int.self, forKey: .maxRounds)
        selection = try values.decodeIfPresent(ReviewModelSelection.self, forKey: .selection)
        speed = try values.decodeIfPresent(ReviewSpeed.self, forKey: .speed) ?? .standard
        priorityLimit = try values.decode(ReviewFinding.Priority.self, forKey: .priorityLimit)
        phase = try values.decode(ReviewLoopPhase.self, forKey: .phase)
        pauseRequested = try values.decode(Bool.self, forKey: .pauseRequested)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        checkoutRoot = try values.decodeIfPresent(String.self, forKey: .checkoutRoot)
        expectedCommit = try values.decodeIfPresent(String.self, forKey: .expectedCommit)
        rounds = try values.decode([ReviewRound].self, forKey: .rounds)
        message = try values.decode(String.self, forKey: .message)
    }
}

struct ReviewLoopAction: Codable, Sendable {
    let id: String
    let kind: String
    let projectID: String?
    let instructions: String?
    let maxRounds: Int?
    let loopID: UUID?
    var selection: ReviewModelSelection? = nil
    var speed: ReviewSpeed? = nil
    var priorityLimit: ReviewFinding.Priority? = nil
}

struct ReviewLoopSnapshot: Codable, Sendable {
    let projects: [ReviewProject]
    let models: [ReviewModel]
    let loops: [ReviewLoop]
    let progress: [String: ReviewLoopProgress]
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
protocol ReviewLoopDriving: Sendable {
    func projects() async throws -> [ReviewProject]
    func repository(at path: String) async throws -> ReviewRepositoryState
    func resolveCommit(_ commit: String, at path: String) async throws -> String
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool
    func createThread(project: ReviewProject, title: String, speed: ReviewSpeed) async throws -> String
    func startTurn(threadID: String, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String
    func readThread(_ threadID: String) async throws -> ReviewThreadState
}

@MainActor
protocol ReviewLoopStoring {
    func load() throws -> [ReviewLoop]
    func save(_ loops: [ReviewLoop]) throws
}
