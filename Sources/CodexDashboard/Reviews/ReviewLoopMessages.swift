import Foundation

struct ReviewLoopAction: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case start, pause, resume, stop, openFile, delete, deleteOlder, deleteAll
    }

    let id: String
    let kind: Kind
    let projectID: String?
    let promptContext: ReviewPromptContext?
    let maxRounds: Int?
    let loopID: UUID?
    var liveTesting: Bool? = nil
    var pushToRemote: Bool? = nil
    var filePath: String? = nil
    var reviewSelection: ReviewModelSelection? = nil
    var fixSelection: ReviewModelSelection? = nil
    var focus: ReviewFocus? = nil
    var speed: ReviewSpeed? = nil
    var priorityLimit: ReviewFinding.Priority? = nil
}

struct ReviewLoopSnapshot: Encodable, Sendable {
    let projects: [ReviewProject]
    let models: [ReviewModel]
    let reviewTypes: [ReviewTypeOption]
    let loops: [ReviewLoopDisplaySnapshot]
    let finishedLoopIDs: [UUID]
    let progress: [String: ReviewLoopProgress]
    let error: String?
    let acknowledgedActionID: String?
}

struct ReviewTypeOption: Codable, Sendable {
    let id: ReviewFocus
    let label: String
    let usesPriorities: Bool
    let supportsProjectContext: Bool
    let supportsLiveTesting: Bool

    init(_ focus: ReviewFocus) {
        id = focus
        label = focus.label
        usesPriorities = focus.usesPriorities
        supportsProjectContext = focus.supportsProjectContext
        supportsLiveTesting = focus.supportsLiveTesting
    }
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

/// Adds derived presentation values without duplicating them in saved loop documents.
struct ReviewLoopDisplaySnapshot: Encodable, Sendable {
    let loop: ReviewLoop

    private enum CodingKeys: String, CodingKey { case completedRoundCount }

    func encode(to encoder: Encoder) throws {
        try loop.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(loop.completedRoundCount, forKey: .completedRoundCount)
    }
}
