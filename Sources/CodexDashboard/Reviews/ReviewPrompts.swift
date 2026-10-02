import Foundation

enum ReviewPrompts {
    static func reviewPrompt(for loop: ReviewLoop) -> String {
        let context = loop.focus.supportsProjectContext ? loop.promptContext.promptSuffix : ""
        let task: String
        switch loop.focus {
        case .bugs:
            task = "Review project for bugs and issues\(context)."
        case .organisation:
            task = "Do a code and content minimisation and organisation review\(context)."
        case .naming:
            task = "Do a code and content minimisation and organisation review, and suggest improvements where naming (e.g. folders, files, classes, variables, functions, UI, etc.) is undescriptive, too long, overly abbreviated, or misleading\(context)."
        case .performance:
            task = "Review project for performance and responsiveness\(context)."
        case .content:
            task = "Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose\(context)."
        }
        return task + "\n\nThis is a read-only review. Fixes will be requested in a separate follow-up after the review is accepted."
    }

    static func fixPrompt(for loop: ReviewLoop, round: ReviewRound) -> String {
        let accepted = round.review?.findings(upTo: loop.priorityLimit) ?? []
        let findings: String
        switch accepted.count {
        case 1: findings = "the finding"
        case 2: findings = "both findings"
        default: findings = "all findings"
        }
        let task: String
        switch loop.focus {
        case .bugs:
            task = "Fix \(findings) and commit"
        case .organisation, .naming, .content, .performance:
            task = "Address \(findings) and commit"
        }
        let prompt = task + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
        guard let review = round.review, accepted.count != review.findings.count else { return prompt }
        let scope = review.findings.enumerated().compactMap { index, finding -> String? in
            guard accepted.contains(finding) else { return nil }
            let priority = finding.priority.map { "[\($0.rawValue)] " } ?? ""
            return "- Finding \(index + 1): \(priority)\(finding.title)"
        }.joined(separator: "\n")
        return prompt
            + "\n\nAddress only these findings from the review. Use their original numbers for withdrawn findings:\n\n" + scope
    }
}
