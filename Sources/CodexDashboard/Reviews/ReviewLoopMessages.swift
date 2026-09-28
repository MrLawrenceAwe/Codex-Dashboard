import Foundation

struct ReviewLoopAction: Codable, Sendable {
    let id: String
    let kind: String
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
