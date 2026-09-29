import Foundation

struct ReviewModel: Codable, Sendable {
    let modelID: String
    let displayName: String
    let supportedReasoningEfforts: [String]
}

struct ReviewModelSelection: Codable, Equatable, Sendable {
    let modelID: String
    let reasoningEffort: String?
}

enum ReviewFocus: String, Codable, CaseIterable, Sendable {
    case bugs, organisation, naming, performance

    var usesPriorities: Bool { self == .bugs || self == .performance }

    var label: String {
        switch self {
        case .bugs: "Bugs and issues"
        case .organisation: "Simplification and structure"
        case .naming: "Simplification, structure and naming"
        case .performance: "Performance and responsiveness"
        }
    }
}

enum ReviewSpeed: String, Codable, Sendable {
    case standard, fast
    var serviceTier: String { self == .fast ? "priority" : "default" }
}

enum ReviewPromptContext: Equatable, Sendable {
    case general
    case personal
    case savedContext(String)

    var promptSuffix: String {
        switch self {
        case .general: ""
        case .personal: " (this is a project for personal use)"
        case .savedContext(let context): " \(context)"
        }
    }
}

extension ReviewPromptContext: Codable {
    private enum CodingKeys: String, CodingKey { case kind, context }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "general": self = .general
        case "personal": self = .personal
        case "savedContext": self = .savedContext(try values.decode(String.self, forKey: .context))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown review prompt context")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .general: try values.encode("general", forKey: .kind)
        case .personal: try values.encode("personal", forKey: .kind)
        case .savedContext(let context):
            try values.encode("savedContext", forKey: .kind)
            try values.encode(context, forKey: .context)
        }
    }
}

struct ReviewProject: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
}

enum ReviewLoopPhase: String, Codable, Sendable {
    case waiting, running, paused, completed, limitReached, stopped, blocked

    var isFinished: Bool {
        switch self {
        case .completed, .limitReached, .stopped, .blocked: true
        case .waiting, .running, .paused: false
        }
    }
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
    }
    let priority: Priority?
    let title: String
    let body: String
}

struct ReviewReport: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case reviewed, blocked }
    let outcome: Outcome
    let findings: [ReviewFinding]
    let summary: String
    func findings(upTo limit: ReviewFinding.Priority?) -> [ReviewFinding] {
        guard let limit else { return findings }
        return findings.filter { $0.priority.map { $0.rank <= limit.rank } ?? false }
    }
}

enum ReviewTurnKind { case review(ReviewFinding.Priority?), fix }

struct ReviewRoundResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case clean, fixed, withdrawn, blocked }
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
    let promptContext: ReviewPromptContext
    let maxRounds: Int
    var reviewSelection: ReviewModelSelection? = nil
    var fixSelection: ReviewModelSelection? = nil
    var focus: ReviewFocus = .bugs
    var speed: ReviewSpeed = .standard
    var priorityLimit: ReviewFinding.Priority? = nil
    var phase: ReviewLoopPhase = .waiting
    var pauseRequested = false
    var branch: String?
    var checkoutRoot: String?
    var expectedCommit: String?
    var rounds: [ReviewRound] = []
    var message = "Waiting for the project to be idle."
}
