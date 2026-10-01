import Foundation

private struct ReviewInspectionError: Error {
    let reason: String
}

/// Single native owner: renderer windows only submit actions and display snapshots.
@MainActor
final class ReviewLoopCoordinator {
    private let store: any ReviewLoopStoring
    private(set) var loops: [ReviewLoop] = []
    private(set) var error: String?
    private var storageFailed = false
    private var advancingIDs: Set<UUID> = []
    private var checkoutOwners: [String: UUID] = [:]

    var threadIDs: Set<String> {
        Set(loops.flatMap { $0.rounds.compactMap(\.threadID) })
    }

    init(store: any ReviewLoopStoring) {
        self.store = store
        do {
            loops = try store.load()
            for index in loops.indices {
                if loops[index].phase == .paused,
                   loops[index].completedRoundCount >= loops[index].maxRounds,
                   loops[index].rounds.last?.result?.outcome == .fixed {
                    loops[index].phase = .limitReached
                }
                if [.running, .waiting].contains(loops[index].phase) {
                    loops[index].phase = .paused
                    loops[index].message = "Dashboard restarted. Resume to reconcile the last round before continuing."
                }
            }
            for loop in loops where !loop.phase.isFinished {
                if let root = loop.checkoutRoot { checkoutOwners[Self.canonicalPath(root)] = loop.id }
            }
            try store.save(loops)
        } catch {
            self.error = "Review loop storage could not be read: \(error.localizedDescription)"
            storageFailed = true
        }
    }

    func apply(_ action: ReviewLoopAction, projects: [ReviewProject]) throws {
        guard !storageFailed else { throw ReviewLoopError(error ?? "Review loop storage is unavailable.") }
        switch action.kind {
        case .start:
            if loops.contains(where: { $0.startActionID == action.id }) { return }
            guard let project = projects.first(where: { $0.id == action.projectID }),
                  let limit = action.maxRounds, (1...20).contains(limit) else {
                throw ReviewLoopError("Choose an available local project and 1–20 rounds.")
            }
            guard let reviewSelection = action.reviewSelection, !reviewSelection.modelID.isEmpty,
                  let fixSelection = action.fixSelection, !fixSelection.modelID.isEmpty else {
                throw ReviewLoopError("Choose a review model and a fix model before starting a loop.")
            }
            guard !loops.contains(where: { !$0.phase.isFinished && ($0.project.id == project.id || Self.canonicalPath($0.project.path) == Self.canonicalPath(project.path)) }) else {
                throw ReviewLoopError("This project already has an active loop. Stop it before starting another.")
            }
            let focus = action.focus ?? .bugs
            let promptContext = focus.supportsProjectContext ? action.promptContext ?? .general : .general
            try persist(ReviewLoop(id: UUID(), startActionID: action.id, project: project, promptContext: promptContext, maxRounds: limit, reviewSelection: reviewSelection, fixSelection: fixSelection, focus: focus, speed: action.speed ?? .standard, priorityLimit: focus.usesPriorities ? action.priorityLimit ?? .p2 : nil, pushToRemote: action.pushToRemote ?? false))
        case .pause, .resume, .stop:
            guard let id = action.loopID, var updated = matchingLoop(id) else {
                throw ReviewLoopError("This review loop has changed. Refresh its controls.")
            }
            guard !updated.phase.isFinished else { return }
            if action.kind == .stop {
                updated.phase = .stopped
                updated.message = "Stopped loop. Stopping its running chat."
            } else if action.kind == .resume, updated.phase == .blocked {
                guard !loops.contains(where: { $0.id != id && !$0.phase.isFinished &&
                    ($0.project.id == updated.project.id || Self.canonicalPath($0.project.path) == Self.canonicalPath(updated.project.path))
                }) else {
                    throw ReviewLoopError("This project already has another active loop. Stop it before resuming this loop.")
                }
                updated.pauseRequested = false
                if let round = updated.rounds.last, round.result == nil || round.result?.outcome == .blocked {
                    guard round.threadID != nil else {
                        throw ReviewLoopError("The previous chat launch was not confirmed. Inspect recent chats before starting a new loop; it will not be sent twice.")
                    }
                    updated.rounds[updated.rounds.count - 1].continuationRequested = true
                    updated.rounds[updated.rounds.count - 1].result = nil
                    updated.phase = .running
                    updated.message = "Checking the review chat after your follow-up."
                } else {
                    updated.phase = .waiting
                    updated.message = "Checking the project before continuing."
                }
            } else if action.kind == .pause, updated.phase != .blocked {
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
        case .openFile:
            throw ReviewLoopError("A file link must be opened from its review card.")
        case .delete, .deleteOlder, .deleteAll:
            let next: [ReviewLoop]
            if action.kind == .deleteAll {
                next = loops.filter { !$0.phase.isFinished }
            } else {
                guard let id = action.loopID,
                      let index = loops.firstIndex(where: { $0.id == id && $0.phase.isFinished }) else {
                    throw ReviewLoopError("This previous review is unavailable. Refresh the list.")
                }
                next = loops.enumerated().compactMap { offset, loop in
                    let shouldDelete = loop.phase.isFinished && (action.kind == .delete ? offset == index : offset < index)
                    return shouldDelete ? nil : loop
                }
            }
            try persistAll(next)
        }
        error = nil
    }

    func stopRunningTask(for id: UUID, using driver: any ReviewLoopDriving) async throws {
        guard let loop = matchingLoop(id), loop.phase == .stopped else { return }
        do {
            if let round = loop.rounds.last, round.result == nil, let threadID = round.threadID {
                try await driver.stopThread(threadID)
            }
        } catch {
            if var updated = matchingLoop(id), updated.phase == .stopped {
                updated.message = "Stopped loop, but could not stop its chat. Open its chat to stop it: \(error.localizedDescription)"
                try persist(updated)
            }
            throw error
        }
        guard var updated = matchingLoop(id), updated.phase == .stopped else { return }
        updated.message = "Stopped loop and its running chat."
        try persist(updated)
    }

    func advance(using driver: any ReviewLoopDriving, threads: [RendererThread]) async {
        let ids = loops.filter { [.waiting, .running].contains($0.phase) }.map(\.id)
        let tasks = ids.map { id in
            Task { @MainActor in
                await self.advance(id: id, using: driver, threads: threads)
            }
        }
        for task in tasks { await task.value }
    }

    private func advance(id: UUID, using driver: any ReviewLoopDriving, threads: [RendererThread]) async {
        guard !advancingIDs.contains(id), !storageFailed,
              let current = activeLoop(matching: id) else { return }
        advancingIDs.insert(id)
        defer { advancingIDs.remove(id) }
        do {
            if current.phase == .waiting {
                try await launch(id: id, using: driver, threads: threads)
            } else {
                try await reconcile(id: id, using: driver, threads: threads)
            }
        } catch let inspectionError as ReviewInspectionError {
            guard !storageFailed, var updated = activeLoop(matching: current.id) else { return }
            updated.phase = .paused
            updated.message = "Could not inspect the review state. Resume to retry: \(inspectionError.reason)"
            do { try persist(updated) } catch { self.error = error.localizedDescription }
        } catch {
            guard !storageFailed, var updated = activeLoop(matching: current.id) else { return }
            updated.phase = .blocked
            updated.message = error.localizedDescription
            do { try persist(updated) } catch { self.error = error.localizedDescription }
        }
    }

    private func launch(id: UUID, using driver: any ReviewLoopDriving, threads: [RendererThread]) async throws {
        guard var updated = matchingLoop(id) else { return }
        let repo = try await inspect { try await driver.repository(at: updated.project.path) }
        guard let current = activeLoop(matching: updated.id, phase: .waiting) else { return }
        updated = current
        let root = Self.canonicalPath(repo.root)
        if let owner = checkoutOwners[root], owner != id,
           let other = matchingLoop(owner), !other.phase.isFinished {
            throw ReviewLoopError("This Git checkout already has an active review loop for \(other.project.name). Stop that loop before starting another.")
        }
        // Reserve synchronously after inspection, before any launch can suspend.
        checkoutOwners[root] = id
        if hasOtherRunningTask(threads, root: repo.root, excluding: nil) { return }
        guard repo.clean else { throw ReviewLoopError("Commit or set aside existing changes before starting a review. The loop will not commit unrelated work.") }
        guard !repo.branch.isEmpty else { throw ReviewLoopError("Check out a branch before starting a review loop.") }
        if let branch = updated.branch, branch != repo.branch { throw ReviewLoopError("The checkout changed branch. Start a new loop for the new branch.") }
        if let head = updated.expectedCommit, head != repo.commit { throw ReviewLoopError("HEAD changed outside the review loop. Inspect the changes before starting a new loop.") }
        guard updated.completedRoundCount < updated.maxRounds else {
            updated.phase = .limitReached
            updated.message = "All configured review rounds completed."
            try persist(updated)
            return
        }
        updated.checkoutRoot = root
        updated.branch = repo.branch
        updated.expectedCommit = repo.commit
        let round = ReviewRound(number: updated.rounds.count + 1, baseCommit: repo.commit)
        updated.rounds.append(round)
        updated.phase = .running
        updated.message = "Starting review \(round.number). \(updated.completedRoundCount) of \(updated.maxRounds) rounds completed."
        // Record intent before any remote side effect. A crash here must not launch twice.
        try persist(updated)
        let threadID = try await driver.createThread(project: updated.project, title: "Review loop · round \(round.number)", speed: updated.speed)
        guard let current = matchingLoop(updated.id) else { return }
        updated = current
        updated.rounds[updated.rounds.count - 1].threadID = threadID
        try persist(updated)
        guard updated.phase == .running else {
            try await stopRunningTask(for: updated.id, using: driver)
            return
        }
        let turnID = try await driver.startTurn(threadID: threadID, projectPath: updated.project.path,
                                               expectedRepository: repo,
                                               prompt: ReviewPrompts.reviewPrompt(for: updated),
                                               kind: .review(updated.priorityLimit), selection: updated.reviewSelection,
                                               speed: updated.speed)
        guard let current = matchingLoop(updated.id) else { return }
        updated = current
        updated.rounds[updated.rounds.count - 1].reviewTurnID = turnID
        if updated.phase == .running {
            updated.message = "Review \(round.number) is running in a fresh chat."
        }
        try persist(updated)
        try await stopRunningTask(for: updated.id, using: driver)
    }

    private func reconcile(id: UUID, using driver: any ReviewLoopDriving, threads: [RendererThread]) async throws {
        guard var updated = matchingLoop(id), var round = updated.rounds.last else { throw ReviewLoopError("Missing review round.") }
        guard let threadID = round.threadID else { throw ReviewLoopError("A previous launch was interrupted before its chat ID was saved. Inspect recent chats before starting a new loop; it will not be sent twice.") }
        let thread = try await inspect { try await driver.readThread(threadID) }
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard let currentRound = updated.rounds.last else { return }
        round = currentRound
        guard Self.canonicalPath(thread.cwd) == Self.canonicalPath(updated.project.path) else { throw ReviewLoopError("The review chat moved to a different checkout.") }
        guard let reviewTurn = round.reviewTurnID.flatMap({ id in thread.turns.first { $0.id == id } }) ?? thread.turns.first,
              round.reviewTurnID == nil || round.reviewTurnID == reviewTurn.id,
              round.continuationRequested == true || thread.turns.count <= (round.fixRequested ? 2 : 1) else {
            throw ReviewLoopError("The review chat has an unexpected turn. Inspect it before starting a new loop.")
        }
        if round.review == nil {
            try await acceptReviewReport(round.continuationRequested == true ? thread.turns.last! : reviewTurn, loop: updated, round: round,
                                         using: driver, threads: threads, threadID: threadID)
        } else if !round.fixRequested {
            try await submitFixTurn(loop: updated, round: round,
                                    using: driver, threads: threads, threadID: threadID)
        } else {
            try await completeRound(thread: thread, loop: updated, round: round,
                                    using: driver, threads: threads, threadID: threadID)
        }
    }

    private func acceptReviewReport(
        _ reviewTurn: ReviewTurnState, loop: ReviewLoop, round: ReviewRound,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        var updated = loop
        var round = round
        if reviewTurn.status == "inProgress" { return }
        try requireCompleted(reviewTurn)
        let report = try ReviewReportContract.review(reviewTurn.finalMessage, priorityLimit: updated.priorityLimit)
        guard report.outcome == .reviewed else { throw ReviewLoopError("Review needs attention: \(report.summary)") }
        let repo = try await validateCheckout(using: driver, loop: updated, threads: threads, threadID: threadID)
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard repo.commit == round.baseCommit else { throw ReviewLoopError("The review changed HEAD. Reviews must leave the checkout unchanged before fixes are requested.") }
        let findings = report.findings(upTo: updated.priorityLimit)
        if !findings.isEmpty, findings.count != report.findings.count {
            throw ReviewLoopError("The review included findings outside the selected priority limit. Inspect its report before asking to address all.")
        }
        round.reviewTurnID = reviewTurn.id
        round.review = report
        if findings.isEmpty {
            round.result = ReviewRoundResult(outcome: .clean, findingCount: 0,
                                             commit: repo.commit, summary: report.summary)
            updated.phase = .completed
            updated.message = "Review \(round.number) found no \(updated.priorityLimit.map { "\($0.rangeLabel) " } ?? "")findings. No fix prompt was sent."
        } else {
            updated.message = "Review \(round.number) found \(findings.count) \(updated.priorityLimit.map { "\($0.rangeLabel) " } ?? "")findings. Preparing the fix prompt."
        }
        updated.rounds[updated.rounds.count - 1] = round
        try persist(updated)
    }

    private func submitFixTurn(
        loop: ReviewLoop, round: ReviewRound,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        var updated = loop
        var round = round
        guard let report = round.review, !report.findings(upTo: updated.priorityLimit).isEmpty else {
            throw ReviewLoopError("The review has no findings to fix.")
        }
        let repo = try await validateCheckout(using: driver, loop: updated, threads: threads, threadID: threadID)
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard repo.commit == round.baseCommit else { throw ReviewLoopError("HEAD changed after the review. Start a new review of the current commit.") }
        round.fixRequested = true
        updated.rounds[updated.rounds.count - 1] = round
        updated.message = "Addressing the \(updated.priorityLimit.map { "\($0.rangeLabel) " } ?? "")findings in review \(round.number), then committing."
        try persist(updated)
        let id = try await driver.startTurn(threadID: threadID, projectPath: updated.project.path,
                                            expectedRepository: repo,
                                            prompt: ReviewPrompts.fixPrompt(for: updated, round: round),
                                            kind: .fix, selection: updated.fixSelection, speed: updated.speed)
        guard let current = matchingLoop(updated.id) else { return }
        updated = current
        updated.rounds[updated.rounds.count - 1].fixTurnID = id
        try persist(updated)
        try await stopRunningTask(for: updated.id, using: driver)
    }

    private func completeRound(
        thread: ReviewThreadState, loop: ReviewLoop, round: ReviewRound,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        var updated = loop
        guard let report = round.review, !report.findings(upTo: updated.priorityLimit).isEmpty else {
            throw ReviewLoopError("The review has no findings to fix.")
        }
        guard let fixTurn = thread.turns.last,
              (round.continuationRequested == true && thread.turns.count >= 2) ||
                (thread.turns.count == 2 && (round.fixTurnID == nil || round.fixTurnID == fixTurn.id)) else {
            throw ReviewLoopError("The fix prompt was not acknowledged. Inspect the chat; it will not be sent twice.")
        }
        if fixTurn.status == "inProgress" { return }
        try requireCompleted(fixTurn)
        let fixReport = try ReviewReportContract.fix(fixTurn.finalMessage)
        let result = fixReport.result
        guard result.outcome != .blocked else { throw ReviewLoopError("Fixes need attention: \(result.summary)") }
        let findings = report.findings(upTo: updated.priorityLimit)
        guard result.findingCount + fixReport.withdrawn.count == findings.count,
              fixReport.withdrawn.allSatisfy({ $0 <= findings.count }) else {
            throw ReviewLoopError("Commit checkpoint failed: the fix report accounted for \(result.findingCount + fixReport.withdrawn.count) of \(findings.count) findings.")
        }
        let reportedCommit = try await result.outcome == .fixed
            ? inspectGitProcess { try await driver.resolveCommit(result.commit, at: updated.project.path) }
            : round.baseCommit
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        let repo = try await validateCheckout(using: driver, loop: updated, threads: threads, threadID: threadID)
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard repo.commit == reportedCommit else {
            throw ReviewLoopError("Commit checkpoint failed: HEAD (\(repo.commit)) differs from the reported fix commit (\(reportedCommit)).")
        }
        if result.outcome == .fixed {
            guard repo.commit != round.baseCommit else {
                throw ReviewLoopError("Commit checkpoint failed: no new fix commit was created.")
            }
            guard try await inspectGitProcess({ try await driver.isAncestor(round.baseCommit, of: repo.commit, at: updated.project.path) }) else {
                throw ReviewLoopError("Commit checkpoint failed: the fix commit is not a descendant of the starting commit.")
            }
        }
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        if result.outcome == .fixed, updated.pushToRemote {
            updated.message = "Fixes committed. Pushing the verified commit to the remote."
            try persist(updated)
            try await driver.pushCommit(at: updated.project.path, expectedRepository: repo)
            guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
            updated = current
        }
        updated.phase = result.outcome == .withdrawn ? .completed : updated.completedRoundCount + 1 >= updated.maxRounds ? .limitReached : updated.pauseRequested ? .paused : .waiting
        updated.message = result.outcome == .withdrawn ? "All review findings were withdrawn. No fix commit was needed."
            : updated.completedRoundCount + 1 >= updated.maxRounds
            ? "All configured review rounds completed."
            : updated.pauseRequested ? "Fixes committed. Paused before the next review." : "Fixes committed. Ready for a fresh review."
        if result.outcome == .fixed, updated.pushToRemote { updated.message += " Fixes pushed to remote." }
        updated.rounds[updated.rounds.count - 1].fixTurnID = fixTurn.id
        updated.rounds[updated.rounds.count - 1].result = ReviewRoundResult(
            outcome: result.outcome, findingCount: result.findingCount, commit: repo.commit, summary: result.summary)
        updated.expectedCommit = repo.commit
        try persist(updated)
    }

    private func validateCheckout(using driver: any ReviewLoopDriving, loop: ReviewLoop,
                            threads: [RendererThread], threadID: String) async throws -> ReviewRepositoryState {
        let repo = try await inspect { try await driver.repository(at: loop.project.path) }
        guard !hasOtherRunningTask(threads, root: repo.root, excluding: threadID) else {
            throw ReviewLoopError("Another chat is running in this checkout. Inspect its changes before continuing.")
        }
        guard repo.clean, repo.branch == loop.branch else {
            throw ReviewLoopError("Commit checkpoint failed: the checkout must be clean and on the original branch.")
        }
        return repo
    }

    private func requireCompleted(_ turn: ReviewTurnState) throws {
        guard turn.status == "completed" else {
            throw ReviewLoopError("The chat was interrupted, failed, or did not start. Open its chat to resolve the issue.")
        }
    }

    private func inspect<T>(_ read: () async throws -> T) async throws -> T {
        do { return try await read() }
        catch { throw ReviewInspectionError(reason: error.localizedDescription) }
    }

    private func inspectGitProcess<T>(_ read: () async throws -> T) async throws -> T {
        do { return try await read() }
        catch let error as ReviewLoopError { throw error }
        catch { throw ReviewInspectionError(reason: error.localizedDescription) }
    }

    private func persist(_ updated: ReviewLoop) throws {
        var next = loops
        if let index = next.firstIndex(where: { $0.id == updated.id }) { next[index] = updated }
        else { next.append(updated) }
        try persistAll(next)
    }

    private func persistAll(_ next: [ReviewLoop]) throws {
        do {
            try store.save(next)
            loops = next
        } catch {
            storageFailed = true
            self.error = "Review loop stopped because its state could not be saved. \(error.localizedDescription)"
            throw ReviewLoopError(self.error!)
        }
    }

    private func matchingLoop(_ id: UUID) -> ReviewLoop? {
        loops.first { $0.id == id }
    }

    private func activeLoop(matching id: UUID, phase: ReviewLoopPhase? = nil) -> ReviewLoop? {
        guard let loop = matchingLoop(id),
              phase.map({ loop.phase == $0 }) ?? [.waiting, .running].contains(loop.phase)
        else { return nil }
        return loop
    }

    private func hasOtherRunningTask(_ threads: [RendererThread], root: String, excluding: String?) -> Bool {
        threads.contains { thread in
            let cwd = Self.canonicalPath(thread.projectPath)
            let root = Self.canonicalPath(root)
            return thread.id != excluding && thread.runState == .running && (cwd == root || cwd.hasPrefix(root + "/"))
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    var progress: [String: ReviewLoopProgress] {
        Dictionary(uniqueKeysWithValues: loops.compactMap { loop in
            ReviewLoopPresentation.progress(for: loop).map { (loop.id.uuidString, $0) }
        })
    }
}
