import Foundation

enum ReviewPrompts {
    static func reviewPrompt(for loop: ReviewLoop) -> String {
        let context = loop.focus.supportsProjectContext ? loop.promptContext.promptSuffix : ""
        switch loop.focus {
        case .bugs:
            return "Review project for bugs and issues\(context)."
        case .organisation:
            return "Do a code minimisation and organisation review\(context)."
        case .naming:
            return "Do a code minimisation and organisation review, and suggest improvements where naming (e.g. folders, files, classes, variables, functions, UI, etc.) is undescriptive, too long, overly abbreviated, or misleading\(context)."
        case .performance:
            return "Review project for performance and responsiveness\(context)."
        case .content:
            return "Review project for content accuracy, clarity, wording, consistency, and completeness\(context)."
        }
    }

    static func fixPrompt(for loop: ReviewLoop, round: ReviewRound) -> String {
        let findings: String
        switch round.review?.findings.count ?? 0 {
        case 1: findings = "the finding"
        case 2: findings = "both findings"
        default: findings = "all findings"
        }
        let task: String
        switch loop.focus {
        case .bugs:
            task = "Fix \(findings) and commit"
        case .organisation, .naming, .content:
            task = "Address \(findings) and commit"
        case .performance:
            task = "Address \(findings) to improve performance and responsiveness. Keep changes proportionate and verify the improvements, then commit"
        }
        return task + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
    }
}
