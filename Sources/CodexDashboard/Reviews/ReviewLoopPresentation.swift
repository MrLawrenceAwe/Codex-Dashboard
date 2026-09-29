import Foundation

enum ReviewLoopPresentation {
    static func progress(for loop: ReviewLoop?) -> ReviewLoopProgress? {
        guard let loop else { return nil }
        let round = loop.rounds.last
        let unfinished = round.map { $0.result == nil } ?? false
        let (upcoming, nextMessage) = nextPrompt(for: loop, round: round, unfinished: unfinished)
        return ReviewLoopProgress(
            step: step(for: loop, round: round),
            currentLabel: loop.phase == .running && unfinished && (round?.review == nil || round?.fixRequested == true)
                ? "Current prompt" : "Latest prompt",
            current: round.map { currentPrompt(for: loop, round: $0) },
            upcoming: upcoming,
            nextMessage: nextMessage,
            threadID: round?.threadID
        )
    }

    private static func step(for loop: ReviewLoop, round: ReviewRound?) -> String {
        switch loop.phase {
        case .completed: "Complete"
        case .limitReached: "Limit reached"
        case .stopped: "Stopped"
        case .blocked: "Needs attention"
        case .paused: "Paused"
        case .waiting: "Waiting to review"
        case .running:
            if round?.fixRequested == true { "Fixing & committing" }
            else if round?.review != nil { "Preparing fixes" }
            else { "Reviewing" }
        }
    }

    private static func currentPrompt(for loop: ReviewLoop, round: ReviewRound) -> ReviewPromptPreview {
        ReviewPromptPreview(
            title: "\(round.fixRequested ? "Fix & commit" : "Review") · round \(round.number)",
            text: round.fixRequested ? fixPrompt(for: loop, round: round) : reviewPrompt(for: loop),
            note: (round.fixRequested ? round.fixTurnID : round.reviewTurnID) == nil
                ? "Submission not yet confirmed." : ""
        )
    }

    private static func nextPrompt(
        for loop: ReviewLoop,
        round: ReviewRound?,
        unfinished: Bool
    ) -> (ReviewPromptPreview?, String) {
        let noNextPrompt = "No further prompts scheduled."
        if loop.phase.isFinished { return (nil, noNextPrompt) }
        if let round, unfinished, !round.fixRequested {
            return (ReviewPromptPreview(
                title: "Fix & commit · round \(round.number)",
                text: fixPrompt(for: loop, round: round),
                note: round.review == nil
                    ? "Only if findings are found. Wording follows the finding count."
                    : "After the checkout passes verification."
            ), noNextPrompt)
        }
        guard loop.rounds.count < loop.maxRounds else {
            return (nil, "Round limit reached. No next review scheduled.")
        }
        let note: String
        if loop.phase == .paused { note = "After resume and checkout verification." }
        else if loop.pauseRequested { note = "After this round pauses and you resume." }
        else if unfinished { note = "After fixes commit and verification passes. HEAD will use that commit." }
        else { note = "After the project is idle and the checkout passes verification." }
        return (ReviewPromptPreview(
            title: "Review · round \(loop.rounds.count + 1)",
            text: reviewPrompt(for: loop),
            note: note
        ), noNextPrompt)
    }

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
        case .organisation, .naming:
            task = "Address \(findings) and commit"
        case .performance:
            task = "Address \(findings) to improve performance and responsiveness. Keep changes proportionate, preserve behaviour, and verify the improvements, then commit"
        }
        return task + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
    }
}
