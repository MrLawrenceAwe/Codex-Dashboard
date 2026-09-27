import Foundation

enum ReviewLoopPresentation {
    static func progress(for loop: ReviewLoop?) -> ReviewLoopProgress? {
        guard let loop else { return nil }
        let round = loop.rounds.last
        let ended = [.completed, .limitReached, .stopped, .blocked].contains(loop.phase)
        let unfinished = round.map { $0.result == nil } ?? false
        var current: ReviewPromptPreview?
        if let round {
            current = ReviewPromptPreview(
                title: "\(round.fixRequested ? "Fix & commit" : "Review") · round \(round.number)",
                text: round.fixRequested ? fixPrompt(for: loop, round: round) : reviewPrompt(for: loop),
                note: (round.fixRequested ? round.fixTurnID : round.reviewTurnID) == nil ? "Submission not yet confirmed." : "")
        }
        let step: String
        switch loop.phase {
        case .completed: step = "Complete"
        case .limitReached: step = "Limit reached"
        case .stopped: step = "Stopped"
        case .blocked: step = "Needs attention"
        case .paused: step = "Paused"
        case .waiting: step = "Waiting to review"
        case .running: step = round?.fixRequested == true ? "Fixing & committing" : round?.review != nil ? "Preparing fixes" : "Reviewing"
        }
        var upcoming: ReviewPromptPreview?
        var nextMessage = "No further prompts scheduled."
        if !ended {
            if let round, unfinished, !round.fixRequested {
                upcoming = ReviewPromptPreview(title: "Fix & commit · round \(round.number)",
                    text: fixPrompt(for: loop, round: round),
                    note: round.review == nil ? "Only if qualifying issues are found. Wording follows the finding count." : "After the checkout passes verification.")
            } else if loop.rounds.count < loop.maxRounds {
                let note = loop.phase == .paused ? "After resume and checkout verification."
                    : loop.pauseRequested ? "After this round pauses and you resume."
                    : unfinished ? "After fixes commit and verification passes. HEAD will use that commit." : "After the project is idle and the checkout passes verification."
                upcoming = ReviewPromptPreview(title: "Review · round \(loop.rounds.count + 1)", text: reviewPrompt(for: loop), note: note)
            } else {
                nextMessage = "Round limit reached. No next review scheduled."
            }
        }
        return ReviewLoopProgress(step: step,
            currentLabel: loop.phase == .running && unfinished && (round?.review == nil || round?.fixRequested == true) ? "Current prompt" : "Latest prompt",
            current: current, upcoming: upcoming, nextMessage: nextMessage, threadID: round?.threadID)
    }

    static func reviewPrompt(for loop: ReviewLoop) -> String {
        let context = loop.instructions.isEmpty ? "" : " \(loop.instructions)"
        return "Review project for bugs and issues\(context)."
    }

    static func fixPrompt(for loop: ReviewLoop, round: ReviewRound) -> String {
        switch round.review?.qualifyingFindings(upTo: loop.priorityLimit).count ?? 0 {
        case 1: return "Fix the finding; commit once"
        case 2: return "Fix both findings; commit once"
        default: return "Fix all findings; commit once"
        }
    }
}
