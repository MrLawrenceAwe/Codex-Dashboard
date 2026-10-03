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
        case .limitReached: "Round limit reached"
        case .stopped: "Stopped"
        case .stopping: "Stopping chat"
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
            text: round.fixRequested ? ReviewPrompts.fixPrompt(for: loop, round: round) : ReviewPrompts.reviewPrompt(for: loop),
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
        if loop.phase.isFinished || loop.phase == .stopping { return (nil, noNextPrompt) }
        if loop.phase == .blocked {
            return (nil, "Open the review chat and provide the missing information or resolve its blocker, then Resume. The loop checks that chat's latest report and commit.")
        }
        if let round, unfinished, !round.fixRequested {
            return (ReviewPromptPreview(
                title: "Fix & commit · round \(round.number)",
                text: ReviewPrompts.fixPrompt(for: loop, round: round),
                note: round.review == nil
                    ? "Only if findings are found. Wording follows the finding count."
                    : "After the checkout passes verification."
            ), noNextPrompt)
        }
        guard loop.completedRoundCount + (unfinished ? 1 : 0) < loop.maxRounds else {
            return (nil, "Round limit reached. No next review scheduled.")
        }
        let note: String
        if loop.phase == .paused { note = "After resume and checkout verification." }
        else if loop.pauseRequested { note = "After this round pauses and you resume." }
        else if unfinished { note = "After fixes commit and verification passes. HEAD will use that commit." }
        else { note = "After the project is idle and the checkout passes verification." }
        return (ReviewPromptPreview(
            title: "Review · round \(loop.rounds.count + 1)",
            text: ReviewPrompts.reviewPrompt(for: loop),
            note: note
        ), noNextPrompt)
    }
}
