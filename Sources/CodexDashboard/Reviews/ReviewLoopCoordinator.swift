import Foundation

/// Single native owner: renderer windows only submit actions and display snapshots.
@MainActor
final class ReviewLoopCoordinator {
    private let store: any ReviewLoopStoring
    private(set) var loop: ReviewLoop?
    private(set) var error: String?
    private var storageFailed = false
    private var isAdvancing = false

    init(store: any ReviewLoopStoring) {
        self.store = store
        do {
            loop = try store.load()
            // Reconcile a known thread on resume, but never repeat an uncertain launch.
            if var recovered = loop, [.running, .waiting].contains(recovered.phase) {
                recovered.phase = .paused
                recovered.message = "Dashboard restarted. Resume to reconcile the last round before continuing."
                try store.save(recovered)
                loop = recovered
            }
        } catch {
            self.error = "Review loop storage could not be read: \(error.localizedDescription)"
            storageFailed = true
        }
    }

    func apply(_ action: ReviewLoopAction, projects: [ReviewProject]) throws {
        guard !storageFailed else { throw ReviewLoopError(error ?? "Review loop storage is unavailable.") }
        switch action.kind {
        case "start":
            if loop?.startActionID == action.id { return }
            guard loop == nil || [.completed, .stopped, .blocked].contains(loop!.phase) else {
                throw ReviewLoopError("Stop the existing loop before starting another.")
            }
            guard let project = projects.first(where: { $0.id == action.projectID }),
                  let limit = action.maxRounds, (1...20).contains(limit) else {
                throw ReviewLoopError("Choose an available local project and 1–20 rounds.")
            }
            let instructions = (action.instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard instructions.count <= 20_000 else { throw ReviewLoopError("Review instructions are too long.") }
            try persist(ReviewLoop(id: UUID(), startActionID: action.id, project: project, instructions: instructions, maxRounds: limit, selection: action.selection, priorityLimit: action.priorityLimit ?? .p2))
        case "pause", "resume", "stop":
            guard var updated = loop, action.loopID == updated.id else {
                throw ReviewLoopError("This review loop has changed. Refresh its controls.")
            }
            guard ![.completed, .stopped, .blocked].contains(updated.phase) else { return }
            if action.kind == "stop" {
                updated.phase = .stopped
                updated.message = "Stopped scheduling reviews. Any active task can finish in its chat."
            } else if action.kind == "pause" {
                if updated.phase == .running {
                    updated.pauseRequested = true
                    updated.message = "Will pause after the current round finishes."
                } else {
                    updated.phase = .paused
                    updated.message = "Paused."
                }
            } else if updated.phase == .paused {
                updated.pauseRequested = false
                updated.phase = updated.rounds.last.map { $0.result == nil } == true ? .running : .waiting
                updated.message = "Checking the project before continuing."
            }
            try persist(updated)
        default: throw ReviewLoopError("Unknown review loop action.")
        }
        error = nil
    }

    func advance(using driver: any ReviewLoopDriving, threads: [RendererThread]) async {
        guard !isAdvancing, !storageFailed, let current = loop,
              [.waiting, .running].contains(current.phase) else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            if current.phase == .waiting {
                try await launch(using: driver, threads: threads)
            } else {
                try await reconcile(using: driver, threads: threads)
            }
        } catch {
            guard !storageFailed, var updated = loop else { return }
            updated.phase = .blocked
            updated.message = error.localizedDescription
            do { try persist(updated) } catch { self.error = error.localizedDescription }
        }
    }

    private func launch(using driver: any ReviewLoopDriving, threads: [RendererThread]) async throws {
        guard var updated = loop else { return }
        let repo = try await driver.repository(at: updated.project.path)
        if hasOtherRunningTask(threads, root: repo.root, excluding: nil) { return }
        guard repo.clean else { throw ReviewLoopError("Commit or set aside existing changes before starting a review. The loop will not commit unrelated work.") }
        guard !repo.branch.isEmpty else { throw ReviewLoopError("Check out a branch before starting a review loop.") }
        if let branch = updated.branch, branch != repo.branch { throw ReviewLoopError("The checkout changed branch. Start a new loop for the new branch.") }
        if let head = updated.expectedCommit, head != repo.commit { throw ReviewLoopError("HEAD changed outside the review loop. Inspect the changes before starting a new loop.") }
        guard updated.rounds.count < updated.maxRounds else {
            updated.phase = .paused
            updated.message = "Round limit reached. No clean review has been confirmed."
            try persist(updated)
            return
        }
        updated.branch = repo.branch
        updated.expectedCommit = repo.commit
        let round = ReviewRound(number: updated.rounds.count + 1, baseCommit: repo.commit)
        updated.rounds.append(round)
        updated.phase = .running
        updated.message = "Starting review \(round.number) of \(updated.maxRounds)."
        // Record intent before any remote side effect. A crash here must not launch twice.
        try persist(updated)
        let threadID = try await driver.createThread(project: updated.project, title: "Review loop · round \(round.number)")
        updated.rounds[updated.rounds.count - 1].threadID = threadID
        try persist(updated)
        let turnID = try await driver.startTurn(threadID: threadID, prompt: Self.reviewPrompt(for: updated, round: round), kind: .review(updated.priorityLimit), selection: updated.selection)
        updated.rounds[updated.rounds.count - 1].reviewTurnID = turnID
        updated.message = "Review \(round.number) is running in a fresh chat."
        try persist(updated)
    }

    private func reconcile(using driver: any ReviewLoopDriving, threads: [RendererThread]) async throws {
        guard var updated = loop, var round = updated.rounds.last else { throw ReviewLoopError("Missing review round.") }
        guard let threadID = round.threadID else { throw ReviewLoopError("A previous launch was interrupted before its task ID was saved. Inspect recent tasks before starting a new loop; it will not be sent twice.") }
        let thread = try await driver.readThread(threadID)
        guard Self.path(thread.cwd) == Self.path(updated.project.path) else { throw ReviewLoopError("The review task moved to a different checkout.") }
        guard let reviewTurn = thread.turns.first,
              round.reviewTurnID == nil || round.reviewTurnID == reviewTurn.id,
              thread.turns.count <= (round.fixRequested ? 2 : 1) else {
            throw ReviewLoopError("The review task has an unexpected turn. Inspect it before starting a new loop.")
        }
        if round.review == nil {
            if reviewTurn.status == "inProgress" { return }
            try requireCompleted(reviewTurn)
            let report: ReviewReport = try decodeReport(reviewTurn)
            guard report.outcome == .reviewed else { throw ReviewLoopError("Review needs attention: \(report.summary)") }
            let repo = try await checkpoint(using: driver, loop: updated, threads: threads, threadID: threadID)
            guard repo.commit == round.baseCommit else { throw ReviewLoopError("The review changed HEAD. Reviews must leave the checkout unchanged before fixes are requested.") }
            if !report.qualifyingFindings(upTo: updated.priorityLimit).isEmpty,
               report.qualifyingFindings(upTo: updated.priorityLimit).count != report.findings.count {
                throw ReviewLoopError("The review included findings outside the selected priority limit. Inspect its report before asking to address all.")
            }
            round.reviewTurnID = reviewTurn.id
            round.review = report
            if report.qualifyingFindings(upTo: updated.priorityLimit).isEmpty {
                round.result = ReviewRoundResult(outcome: .clean, findings: 0,
                                                 commit: repo.commit, summary: report.summary)
                updated.phase = .completed
                updated.message = "Review \(round.number) found no \(updated.priorityLimit.label) issues. No fix prompt was sent."
            } else {
                updated.message = "Review \(round.number) found \(report.qualifyingFindings(upTo: updated.priorityLimit).count) \(updated.priorityLimit.label) issues. Preparing the fix prompt."
            }
            updated.rounds[updated.rounds.count - 1] = round
            try persist(updated)
            return
        }
        guard let report = round.review, !report.qualifyingFindings(upTo: updated.priorityLimit).isEmpty else { throw ReviewLoopError("The review has no qualifying findings to fix.") }
        if !round.fixRequested {
            let repo = try await checkpoint(using: driver, loop: updated, threads: threads, threadID: threadID)
            guard repo.commit == round.baseCommit else { throw ReviewLoopError("HEAD changed after the review. Start a new review of the current commit.") }
            round.fixRequested = true
            updated.rounds[updated.rounds.count - 1] = round
            updated.message = "Addressing the \(updated.priorityLimit.label) findings in review \(round.number), then committing."
            try persist(updated)
            let id = try await driver.startTurn(threadID: threadID, prompt: Self.fixPrompt(for: updated, round: round), kind: .fix, selection: updated.selection)
            updated.rounds[updated.rounds.count - 1].fixTurnID = id
            try persist(updated)
            return
        }
        guard thread.turns.count == 2, let fixTurn = thread.turns.last,
              round.fixTurnID == nil || round.fixTurnID == fixTurn.id else {
            throw ReviewLoopError("The fix prompt was not acknowledged. Inspect the task; it will not be sent twice.")
        }
        if fixTurn.status == "inProgress" { return }
        try requireCompleted(fixTurn)
        let result: ReviewRoundResult = try decodeReport(fixTurn)
        guard result.outcome == .fixed else { throw ReviewLoopError("Fixes need attention: \(result.summary)") }
        let repo = try await checkpoint(using: driver, loop: updated, threads: threads, threadID: threadID)
        guard repo.commit == result.commit, result.findings == report.qualifyingFindings(upTo: updated.priorityLimit).count,
              repo.commit != round.baseCommit,
              try await driver.isAncestor(round.baseCommit, of: repo.commit, at: updated.project.path) else {
            throw ReviewLoopError("Commit checkpoint failed: all qualifying fixes must be committed on top of the starting commit, and HEAD must match the fix report.")
        }
        updated.phase = updated.pauseRequested || updated.rounds.count >= updated.maxRounds ? .paused : .waiting
        updated.message = updated.rounds.count >= updated.maxRounds
            ? "Round limit reached after committing fixes. No clean review has been confirmed."
            : updated.pauseRequested ? "Fixes committed. Paused before the next review." : "Fixes committed. Ready for a fresh review."
        updated.rounds[updated.rounds.count - 1].fixTurnID = fixTurn.id
        updated.rounds[updated.rounds.count - 1].result = result
        updated.expectedCommit = repo.commit
        try persist(updated)
    }

    private func checkpoint(using driver: any ReviewLoopDriving, loop: ReviewLoop,
                            threads: [RendererThread], threadID: String) async throws -> ReviewRepositoryState {
        let repo = try await driver.repository(at: loop.project.path)
        guard !hasOtherRunningTask(threads, root: repo.root, excluding: threadID) else {
            throw ReviewLoopError("Another task is running in this checkout. Inspect its changes before continuing.")
        }
        guard repo.clean, repo.branch == loop.branch else {
            throw ReviewLoopError("Commit checkpoint failed: the checkout must be clean and on the original branch.")
        }
        return repo
    }

    private func requireCompleted(_ turn: ReviewTurnState) throws {
        guard turn.status == "completed" else {
            throw ReviewLoopError("The task was interrupted, failed, or did not start. Open its chat to resolve the issue.")
        }
    }

    private func decodeReport<T: Decodable>(_ turn: ReviewTurnState) throws -> T {
        guard let text = turn.finalMessage,
              let result = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else {
            throw ReviewLoopError("The task did not return a valid structured report. Open its chat to inspect the result.")
        }
        return result
    }

    private func persist(_ updated: ReviewLoop) throws {
        do { try store.save(updated); loop = updated }
        catch {
            storageFailed = true
            self.error = "Review loop stopped because its state could not be saved. \(error.localizedDescription)"
            throw ReviewLoopError(self.error!)
        }
    }

    private func hasOtherRunningTask(_ threads: [RendererThread], root: String, excluding: String?) -> Bool {
        threads.contains { thread in
            let cwd = Self.path(thread.projectPath)
            let root = Self.path(root)
            return thread.id != excluding && thread.runState == .running && (cwd == root || cwd.hasPrefix(root + "/"))
        }
    }

    private static func path(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func reviewPrompt(for loop: ReviewLoop, round: ReviewRound) -> String {
        """
        Review this project for actionable bugs and issues at priority \(loop.priorityLimit.label). Report only these priorities: \(loop.priorityLimit.included.joined(separator: ", ")). Independently inspect the current code. This is a fresh review: do not read prior review chats or summaries. Follow the repository's AGENTS.md instructions.

        Work only in this checkout: \(loop.project.path)
        Expected starting HEAD: \(round.baseCommit)
        Verify HEAD and a clean working tree before reviewing. If either differs, report blocked.
        REVIEW ONLY in this turn: do not edit files, fix issues, commit, push, change branches, create worktrees, or launch more chats. Report concrete, actionable findings with priority, title, and a body explaining the evidence, affected file/lines, and impact. Do not invent findings to fill a quota. Report reviewed with an empty findings array when there are no qualifying findings. Report blocked if you cannot complete the review or need user input.
        If a later message asks you to address findings and commit, address the findings from this review and commit only those changes on the current branch. Do not push or rewrite existing commits. Use the supplied fix-report schema, reporting fixed only when all findings are addressed and committed, or blocked if you cannot do so. The commit field must be the full final HEAD. Leave the working tree clean.

        Additional review instructions:
        \(loop.instructions.isEmpty ? "None." : loop.instructions)

        Return the required JSON review report: outcome (reviewed or blocked), findings (array of priority/title/body objects), and summary. If no findings meet the selected priority limit, Dashboard stops without sending a fix prompt. Otherwise it sends a separate address-and-commit message in this chat.
        """
    }

    static func fixPrompt(for loop: ReviewLoop, round: ReviewRound) -> String {
        switch round.review?.qualifyingFindings(upTo: loop.priorityLimit).count ?? 0 {
        case 1: return "Address and commit"
        case 2: return "Address both and commit"
        default: return "Address all and commit"
        }
    }
}
