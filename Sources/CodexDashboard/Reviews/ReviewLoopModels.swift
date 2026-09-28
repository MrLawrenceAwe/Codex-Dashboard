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

enum ReviewFocus: String, Codable, CaseIterable, Sendable {
    case bugs, organisation, naming, performance

    var usesPriorities: Bool { self == .bugs || self == .performance }
}

enum ReviewSpeed: String, Codable, Sendable {
    case standard, fast
    var serviceTier: String { self == .fast ? "priority" : "default" }
}

enum ReviewProjectType: Equatable, Sendable {
    case general
    case personal
    case savedContext(String)

    var promptContext: String {
        switch self {
        case .general: ""
        case .personal: " (this is a project for personal use)"
        case .savedContext(let context): " \(context)"
        }
    }
}

extension ReviewProjectType: Codable {
    private enum CodingKeys: String, CodingKey { case kind, context }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "general": self = .general
        case "personal": self = .personal
        case "savedContext": self = .savedContext(try values.decode(String.self, forKey: .context))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown review project type")
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
    let projectType: ReviewProjectType
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

extension ReviewLoop {
    private enum CodingKeys: String, CodingKey {
        case id, startActionID, project, projectType, instructions, maxRounds, reviewSelection, fixSelection, selection, focus, speed,
             priorityLimit, phase, pauseRequested, branch, checkoutRoot, expectedCommit, rounds, message
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        startActionID = try values.decode(String.self, forKey: .startActionID)
        project = try values.decode(ReviewProject.self, forKey: .project)
        if let projectType = try values.decodeIfPresent(ReviewProjectType.self, forKey: .projectType) {
            self.projectType = projectType
        } else {
            let previousContext = try values.decode(String.self, forKey: .instructions)
            switch previousContext {
            case "": projectType = .general
            case "(this is a project for personal use)": projectType = .personal
            default: projectType = .savedContext(previousContext)
            }
        }
        maxRounds = try values.decode(Int.self, forKey: .maxRounds)
        let previousSelection = try values.decodeIfPresent(ReviewModelSelection.self, forKey: .selection)
        reviewSelection = try values.decodeIfPresent(ReviewModelSelection.self, forKey: .reviewSelection) ?? previousSelection
        fixSelection = try values.decodeIfPresent(ReviewModelSelection.self, forKey: .fixSelection) ?? previousSelection
        focus = try values.decodeIfPresent(ReviewFocus.self, forKey: .focus) ?? .bugs
        speed = try values.decodeIfPresent(ReviewSpeed.self, forKey: .speed) ?? .standard
        priorityLimit = focus.usesPriorities
            ? try values.decodeIfPresent(ReviewFinding.Priority.self, forKey: .priorityLimit) ?? .p2
            : nil
        phase = try values.decode(ReviewLoopPhase.self, forKey: .phase)
        pauseRequested = try values.decode(Bool.self, forKey: .pauseRequested)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        checkoutRoot = try values.decodeIfPresent(String.self, forKey: .checkoutRoot)
        expectedCommit = try values.decodeIfPresent(String.self, forKey: .expectedCommit)
        rounds = try values.decode([ReviewRound].self, forKey: .rounds)
        message = try values.decode(String.self, forKey: .message)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(startActionID, forKey: .startActionID)
        try values.encode(project, forKey: .project)
        try values.encode(projectType, forKey: .projectType)
        try values.encode(maxRounds, forKey: .maxRounds)
        try values.encodeIfPresent(reviewSelection, forKey: .reviewSelection)
        try values.encodeIfPresent(fixSelection, forKey: .fixSelection)
        try values.encode(focus, forKey: .focus)
        try values.encode(speed, forKey: .speed)
        try values.encodeIfPresent(priorityLimit, forKey: .priorityLimit)
        try values.encode(phase, forKey: .phase)
        try values.encode(pauseRequested, forKey: .pauseRequested)
        try values.encodeIfPresent(branch, forKey: .branch)
        try values.encodeIfPresent(checkoutRoot, forKey: .checkoutRoot)
        try values.encodeIfPresent(expectedCommit, forKey: .expectedCommit)
        try values.encode(rounds, forKey: .rounds)
        try values.encode(message, forKey: .message)
    }
}
