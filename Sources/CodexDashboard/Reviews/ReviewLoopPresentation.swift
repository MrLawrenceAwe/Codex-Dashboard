import Foundation

enum ReviewLoopPresentation {
    static func progress(for loop: ReviewLoop?) -> ReviewLoopProgress? {
        guard let loop else { return nil }
        let round = loop.rounds.last
        let unfinished = round.map { $0.result == nil } ?? false
        let (upcoming, nextMessage) = nextPrompt(for: loop, round: round, unfinished: unfinished)
        return ReviewLoopProgress(
            step: step(for: loop, round: round),
            currentLabel: "Configured prompt preview",
            current: round.map { configuredPromptPreview(for: loop, round: $0) },
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
        case .awaitingExtensionReload: "Waiting for extension reload"
        case .paused: "Paused"
        case .waiting: "Waiting to review"
        case .running:
            if round?.fixVerification != nil { "Verifying fixes at current HEAD" }
            else if round?.fixRequested == true { "Fixing & committing" }
            else if round?.review != nil { "Preparing fixes" }
            else { "Reviewing" }
        }
    }

    /// Reconstructed from current settings; this is not a record of the submitted turn.
    private static func configuredPromptPreview(for loop: ReviewLoop, round: ReviewRound) -> ReviewPromptPreview {
        if let verification = round.fixVerification {
            return ReviewPromptPreview(
                title: "Verify fixes · round \(round.number)",
                text: ReviewPrompts.verifyFix(for: loop, round: round, commit: verification.commit),
                note: verification.turnID == nil ? "Submission not yet confirmed." : ""
            )
        }
        return ReviewPromptPreview(
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
        if loop.phase == .awaitingExtensionReload, let round {
            return (ReviewPromptPreview(title: "Continue · round \(round.number)",
                                        text: ReviewPrompts.extensionReloadContinuation(for: loop, round: round),
                                        note: "Reload the extension manually, then select Extension reloaded — continue."), "")
        }
        if loop.phase == .blocked {
            return (nil, "Resume continues failed or interrupted work in the same chat. For a completed report that needs attention, resolve its blocker in the chat, then Resume to check the latest report and commit.")
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
        else if unfinished { note = "After fixes commit and verification passes. The next review uses the verified HEAD." }
        else { note = "After the project is idle and the checkout passes verification." }
        return (ReviewPromptPreview(
            title: "Review · round \(loop.rounds.count + 1)",
            text: ReviewPrompts.reviewPrompt(for: loop),
            note: note
        ), noNextPrompt)
    }
}
