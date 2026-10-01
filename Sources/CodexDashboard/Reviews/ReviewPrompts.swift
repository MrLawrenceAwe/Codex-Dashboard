import Foundation

enum ReviewPrompts {
    static func reviewPrompt(for loop: ReviewLoop) -> String {
        let context = loop.focus.supportsProjectContext ? loop.promptContext.promptSuffix : ""
        let task: String
        switch loop.focus {
        case .bugs:
            task = "Review project for bugs and issues\(context)."
        case .organisation:
            task = "Do a code and content minimisation and organisation review\(context). Identify opportunities to remove duplication and unnecessary complexity while preserving clarity and useful information."
        case .naming:
            task = "Do a code and content minimisation and organisation review, and suggest improvements where naming (e.g. folders, files, classes, variables, functions, UI, etc.) is undescriptive, too long, overly abbreviated, or misleading\(context). Identify opportunities to remove duplication and unnecessary complexity while preserving clarity and useful information."
        case .performance:
            task = "Review project for performance and responsiveness\(context)."
        case .content:
            task = "Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose\(context)."
        }
        return task + "\n\nThis is a read-only review. Report findings and recommendations only. Do not edit, create, delete, or rename project files, apply fixes, commit, or push. Leave HEAD and the working tree unchanged. Run checks only if they leave the checkout unchanged; put temporary files outside the project. Fixes will be requested in a separate follow-up after the review is accepted."
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
