import Foundation

struct ReviewLoopAction: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case start, pause, resume, stop
    }

    let id: String
    let kind: Kind
    let projectID: String?
    let promptContext: ReviewPromptContext?
    let maxRounds: Int?
    let loopID: UUID?
    var reviewSelection: ReviewModelSelection? = nil
    var fixSelection: ReviewModelSelection? = nil
    var focus: ReviewFocus? = nil
    var speed: ReviewSpeed? = nil
    var priorityLimit: ReviewFinding.Priority? = nil
}

struct ReviewLoopSnapshot: Codable, Sendable {
    let projects: [ReviewProject]
    let models: [ReviewModel]
    let reviewTypes: [ReviewTypeOption]
    let loops: [ReviewLoop]
    let progress: [String: ReviewLoopProgress]
    let error: String?
    let acknowledgedActionID: String?
}

struct ReviewTypeOption: Codable, Sendable {
    let id: ReviewFocus
    let label: String
    let usesPriorities: Bool

    init(_ focus: ReviewFocus) {
        id = focus
        label = focus.label
        usesPriorities = focus.usesPriorities
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
