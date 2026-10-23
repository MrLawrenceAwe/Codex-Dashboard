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
    private var stoppingIDs: Set<UUID> = []
    private var resumeRequestedIDs: Set<UUID> = []
    private var workspaceOwners: [String: UUID] = [:]

    var threadIDs: Set<String> {
        Set(loops.flatMap { $0.rounds.compactMap(\.threadID) })
    }

    init(store: any ReviewLoopStoring) {
        self.store = store
        do {
            loops = try store.load()
            for index in loops.indices {
                let previous = loops[index]
                if loops[index].phase == .paused,
                   loops[index].completedRoundCount >= loops[index].maxRounds,
                   loops[index].rounds.last?.result?.outcome == .fixed {
                    loops[index].phase = .limitReached
                }
                if [.running, .waiting].contains(loops[index].phase) {
                    loops[index].phase = .paused
                    loops[index].message = "Dashboard restarted. Resume to reconcile the last round before continuing."
                }
                if loops[index] != previous {
                    loops[index].updatedAt = Date.now.timeIntervalSince1970
                }
            }
            for loop in loops where !loop.phase.isFinished {
                if let root = loop.workspaceRoot { workspaceOwners[FileSystemPath.canonicalPath(root)] = loop.id }
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
            guard try startLoop(action, projects: projects) else { return }
        case .setMuteTestPlayback:
            try setMuteTestPlayback(action)
        case .pause, .resume, .stop:
            guard try applyControlAction(action) else { return }
        case .openFile:
            throw ReviewLoopError("A file link must be opened from its review card.")
        case .delete, .deleteOlder, .deleteAll:
            try deleteHistory(action)
        }
        error = nil
    }

    private func startLoop(_ action: ReviewLoopAction, projects: [ReviewProject]) throws -> Bool {
        if loops.contains(where: { $0.startActionID == action.id }) { return false }
        guard let project = projects.first(where: { $0.id == action.projectID }),
              let limit = action.maxRounds, (1...20).contains(limit) else {
            throw ReviewLoopError("Choose an available local project and 1–20 rounds.")
        }
        guard let reviewSelection = action.reviewSelection, !reviewSelection.modelID.isEmpty,
              let fixSelection = action.fixSelection, !fixSelection.modelID.isEmpty else {
            throw ReviewLoopError("Choose a review model and a fix model before starting a loop.")
        }
        guard !loops.contains(where: { !$0.phase.isFinished && ($0.project.id == project.id || FileSystemPath.canonicalPath($0.project.path) == FileSystemPath.canonicalPath(project.path)) }) else {
            throw ReviewLoopError("This project already has an active loop. Stop it before starting another.")
        }
        let reviewType = action.reviewType ?? .bugs
        let promptContext = reviewType.supportsProjectContext ? action.promptContext ?? .general : .general
        let liveTesting = reviewType.supportsLiveTesting && (action.liveTesting ?? false)
        let loop = ReviewLoop(
            id: UUID(),
            startActionID: action.id,
            project: project,
            promptContext: promptContext,
            maxRounds: limit,
            reviewSelection: reviewSelection,
            fixSelection: fixSelection,
            reviewType: reviewType,
            speed: action.speed ?? .standard,
            priorityLimit: reviewType.usesPriorities ? action.priorityLimit ?? .p2 : nil,
            liveTesting: liveTesting,
            reloadExtensionBeforeTesting: liveTesting && (action.reloadExtensionBeforeTesting ?? false),
            muteTestPlayback: liveTesting && (action.muteTestPlayback ?? false),
            pushToRemote: action.pushToRemote ?? false
        )
        try persist(loop)
        return true
    }

    private func setMuteTestPlayback(_ action: ReviewLoopAction) throws {
        guard let id = action.loopID, var updated = matchingLoop(id),
              !updated.phase.isFinished, updated.phase != .stopping,
              updated.liveTesting, updated.reviewType.supportsLiveTesting,
              let muteTestPlayback = action.muteTestPlayback else {
            throw ReviewLoopError("Mute test playback requires an active loop with live testing enabled.")
        }
        updated.muteTestPlayback = muteTestPlayback
        try persist(updated)
    }

    private func applyControlAction(_ action: ReviewLoopAction) throws -> Bool {
        guard let id = action.loopID, var updated = matchingLoop(id) else {
            throw ReviewLoopError("This review loop has changed. Refresh its controls.")
        }
        guard !updated.phase.isFinished else { return false }
        switch action.kind {
        case .stop:
            stopLoop(&updated)
        case .pause:
            guard updated.phase != .stopping else { return false }
            pauseLoop(&updated)
        case .resume:
            guard updated.phase != .stopping else { return false }
            try resumeLoop(&updated)
        default:
            preconditionFailure("Expected a loop control action")
        }
        try persist(updated)
        return true
    }

    private func stopLoop(_ loop: inout ReviewLoop) {
        loop.phase = loop.rounds.last.map { $0.result == nil } == true ? .stopping : .stopped
        loop.message = loop.phase == .stopping ? "Stopping its running chat." : "Stopped loop."
    }

    private func pauseLoop(_ loop: inout ReviewLoop) {
        guard loop.phase != .blocked else { return }
        if loop.phase == .running {
            loop.pauseRequested = true
            loop.message = "Will pause after the current round finishes."
        } else {
            loop.phase = .paused
            loop.message = "Paused."
        }
    }

    private func resumeLoop(_ loop: inout ReviewLoop) throws {
        switch loop.phase {
        case .awaitingExtensionReload:
            loop.rounds[loop.rounds.count - 1].extensionReloadContinuationPending = true
            loop.phase = .running
            loop.message = "Extension reload confirmed. Preparing to continue the same chat."
        case .blocked:
            guard !loops.contains(where: { $0.id != loop.id && !$0.phase.isFinished &&
                ($0.project.id == loop.project.id || FileSystemPath.canonicalPath($0.project.path) == FileSystemPath.canonicalPath(loop.project.path))
            }) else {
                throw ReviewLoopError("This project already has another active loop. Stop it before resuming this loop.")
            }
            loop.pauseRequested = false
            if let round = loop.rounds.last, round.result == nil || round.result?.outcome == .blocked {
                guard round.threadID != nil else {
                    throw ReviewLoopError("The previous chat launch was not confirmed. Inspect recent chats before starting a new loop; it will not be sent twice.")
                }
                loop.rounds[loop.rounds.count - 1].allowsFollowUpTurns = true
                loop.rounds[loop.rounds.count - 1].result = nil
                loop.phase = .running
                resumeRequestedIDs.insert(loop.id)
                loop.message = "Checking the review chat and continuing interrupted work."
            } else {
                loop.phase = .waiting
                loop.message = "Checking the project before continuing."
            }
        case .paused:
            loop.pauseRequested = false
            loop.phase = loop.rounds.last.map { $0.result == nil } == true ? .running : .waiting
            if loop.phase == .running { resumeRequestedIDs.insert(loop.id) }
            loop.message = "Checking the project before continuing."
        default:
            break
        }
    }

    private func deleteHistory(_ action: ReviewLoopAction) throws {
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

    func stopRunningTask(for id: UUID, using driver: any ReviewLoopDriving) async throws {
        guard !advancingIDs.contains(id), !stoppingIDs.contains(id),
              let loop = matchingLoop(id), loop.phase == .stopping else { return }
        stoppingIDs.insert(id)
        defer { stoppingIDs.remove(id) }
        var chatMissing = false
        do {
            // No prompt is submitted until the created thread ID is saved.
            // After advancement finishes, an unknown creation has no running turn.
            if let threadID = loop.rounds.last?.threadID {
                try await driver.interruptLatestTurn(threadID)
            }
        } catch is ReviewChatMissingError {
            chatMissing = true
        } catch {
            if var updated = matchingLoop(id), updated.phase == .stopping {
                updated.message = "Stopping loop, but could not stop its chat. The workspace remains reserved; retry Stop or open its chat: \(error.localizedDescription)"
                try persist(updated)
            }
            throw error
        }
        guard var updated = matchingLoop(id), updated.phase == .stopping else { return }
        updated.phase = .stopped
        updated.message = chatMissing ? "Stopped loop. Its review chat was deleted or is no longer available." : "Stopped loop and its running chat."
        try persist(updated)
    }

    func advance(using driver: any ReviewLoopDriving, threads: [RendererThread]) async {
        let ids = loops.filter { [.waiting, .running, .stopping].contains($0.phase) }.map(\.id)
        let tasks = ids.map { id in
            Task { @MainActor in
                await self.advance(id: id, using: driver, threads: threads)
            }
        }
        for task in tasks { await task.value }
    }

    private func advance(id: UUID, using driver: any ReviewLoopDriving, threads: [RendererThread]) async {
        guard !advancingIDs.contains(id), !storageFailed else { return }
        advancingIDs.insert(id)
        await advanceRound(id: id, using: driver, threads: threads)
        advancingIDs.remove(id)
        // A stop requested during creation/submission must wait until its IDs
        // are saved. Otherwise a late turn can start after the workspace is released.
        do { try await stopRunningTask(for: id, using: driver) }
        catch { /* The stopping loop retains its workspace and its retry message. */ }
    }

    private func advanceRound(id: UUID, using driver: any ReviewLoopDriving, threads: [RendererThread]) async {
        guard let current = activeLoop(matching: id) else { return }
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
        let workspace = try await inspect { try await driver.workspace(at: updated.project.path) }
        guard let current = activeLoop(matching: updated.id, phase: .waiting) else { return }
        updated = current
        let root = FileSystemPath.canonicalPath(workspace.root)
        if let owner = workspaceOwners.first(where: { otherRoot, owner in
            owner != id && pathsOverlap(root, otherRoot) && matchingLoop(owner)?.phase.isFinished == false
        })?.value, let other = matchingLoop(owner) {
            throw ReviewLoopError("This project folder already has an active review loop for \(other.project.name). Stop that loop before starting another.")
        }
        // Reserve synchronously after inspection, before any launch can suspend.
        workspaceOwners[root] = id
        if hasOtherRunningTask(threads, root: workspace.root, excluding: nil) { return }
        guard workspace.git?.isClean != false else { throw ReviewLoopError("Commit or set aside existing changes before starting a review. The loop will not commit unrelated work.") }
        if workspace.kind == .folder, updated.pushToRemote {
            throw ReviewLoopError("Remote push requires Git. Stop this loop and start a folder loop with remote push off.")
        }
        if let kind = updated.workspaceKind, kind != workspace.kind {
            throw ReviewLoopError("The project changed between Git and folder mode. Start a new loop for its current files.")
        }
        guard workspace.git?.branch.isEmpty != true else { throw ReviewLoopError("Check out a branch before starting a review loop.") }
        if let git = workspace.git, let branch = updated.branch, branch != git.branch { throw ReviewLoopError("The checkout changed branch. Start a new loop for the new branch.") }
        // A fresh Git review adopts committed work made after the previous round
        // completed. In-flight rounds keep their original checkpoint in reconcile.
        if let head = updated.expectedRevision, head != workspace.revision,
           !(workspace.kind == .git && updated.rounds.last?.result?.outcome == .fixed) {
            throw ReviewLoopError("The project changed outside the review loop. Inspect the changes before starting a new loop.")
        }
        guard updated.completedRoundCount < updated.maxRounds else {
            updated.phase = .limitReached
            updated.message = "All configured review rounds completed."
            try persist(updated)
            return
        }
        updated.workspaceKind = workspace.kind
        updated.workspaceRoot = root
        updated.branch = workspace.git?.branch
        updated.expectedRevision = workspace.revision
        let round = ReviewRound(number: updated.rounds.count + 1, baseRevision: workspace.revision)
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
            return
        }
        let turnID = try await driver.startTurn(threadID: threadID, projectPath: updated.project.path,
                                               expectedWorkspace: workspace,
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
    }

    private func reconcile(id: UUID, using driver: any ReviewLoopDriving, threads: [RendererThread]) async throws {
        guard var updated = matchingLoop(id), var round = updated.rounds.last else { throw ReviewLoopError("Missing review round.") }
        guard let threadID = round.threadID else { throw ReviewLoopError("A previous launch was interrupted before its chat ID was saved. Inspect recent chats before starting a new loop; it will not be sent twice.") }
        let reportTurnIDs = Set([round.reviewTurnID, round.fixTurnID,
                                 round.fixVerification?.sourceFixTurnID].compactMap { $0 })
        let thread = try await inspect { try await driver.readThread(threadID, reportTurnIDs: reportTurnIDs) }
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard let currentRound = updated.rounds.last else { return }
        round = currentRound
        guard FileSystemPath.canonicalPath(thread.cwd) == FileSystemPath.canonicalPath(updated.project.path) else { throw ReviewLoopError("The review chat moved to a different project folder.") }
        guard let reviewTurn = round.reviewTurnID.flatMap({ id in thread.turns.first { $0.id == id } }) ?? thread.turns.first,
              round.reviewTurnID == nil || round.reviewTurnID == reviewTurn.id,
              round.allowsFollowUpTurns || thread.turns.count <= (round.fixRequested ? 2 : 1) else {
            throw ReviewLoopError("The review chat has an unexpected turn. Inspect it before starting a new loop.")
        }
        let wasResumed = resumeRequestedIDs.remove(id) != nil
        if wasResumed,
           let latest = thread.turns.last, [.interrupted, .failed].contains(latest.status) {
            if let verification = round.fixVerification {
                guard verification.turnID != nil else {
                    throw ReviewLoopError("The verification launch was not acknowledged. Inspect the chat; it will not be sent twice.")
                }
                let workspace = try await validateWorkspace(using: driver, loop: updated, threads: threads, threadID: threadID)
                try await submitFixVerification(loop: updated, round: round, sourceFixTurnID: verification.sourceFixTurnID,
                                                workspace: workspace, using: driver, threadID: threadID)
                return
            }
            try await continueInterruptedTurn(loop: updated, round: round, using: driver, threads: threads, threadID: threadID)
            return
        }
        if wasResumed, let verification = round.fixVerification, verification.turnID != nil,
           let latest = thread.turns.last, latest.status == .completed, latest.id != verification.turnID {
            // Resume explicitly reconciles a corrected verification report from the same chat.
            round.fixVerification?.turnID = latest.id
            updated.rounds[updated.rounds.count - 1] = round
            try persist(updated)
        }
        if round.extensionReloadContinuationPending {
            try await continueAfterExtensionReload(loop: updated, round: round, thread: thread, using: driver, threads: threads, threadID: threadID)
            return
        }
        if round.review == nil {
            try await acceptReviewReport(round.allowsFollowUpTurns ? thread.turns.last! : reviewTurn, loop: updated, round: round,
                                         using: driver, threads: threads, threadID: threadID)
        } else if !round.fixRequested {
            try await submitFixTurn(loop: updated, round: round,
                                    using: driver, threads: threads, threadID: threadID)
        } else {
            try await reconcileFixResult(thread: thread, loop: updated, round: round,
                                    using: driver, threads: threads, threadID: threadID)
        }
    }

    private func acceptReviewReport(
        _ reviewTurn: ReviewTurnState, loop: ReviewLoop, round: ReviewRound,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        var updated = loop
        var round = round
        if reviewTurn.status == .inProgress { return }
        try requireCompleted(reviewTurn)
        if try await waitForExtensionReload(reviewTurn, loop: updated, using: driver, threads: threads, threadID: threadID) { return }
        let report = try ReviewReportContract.review(reviewTurn.finalMessage, priorityLimit: updated.priorityLimit)
        guard report.outcome == .reviewed else { throw ReviewLoopError("Review needs attention: \(report.summary)") }
        let workspace = try await validateWorkspace(using: driver, loop: updated, threads: threads, threadID: threadID, policy: .unchangedReview(baseRevision: round.baseRevision))
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        let findings = report.findings(upTo: updated.priorityLimit)
        round.reviewTurnID = reviewTurn.id
        round.review = report
        if findings.isEmpty {
            round.result = ReviewRoundResult(outcome: .clean, addressedFindingCount: 0,
                                             fixCommit: nil, summary: report.summary, verifiedRevision: workspace.revision)
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
        let workspace = try await validateWorkspace(using: driver, loop: updated, threads: threads, threadID: threadID)
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard workspace.revision == round.baseRevision else { throw ReviewLoopError("The project changed after the review. Start a new review of the current files.") }
        round.fixRequested = true
        updated.rounds[updated.rounds.count - 1] = round
        updated.message = "Addressing the \(updated.priorityLimit.map { "\($0.rangeLabel) " } ?? "")findings in review \(round.number)" + (workspace.kind == .folder ? ", then verifying the files." : ", then committing.")
        try persist(updated)
        let id = try await driver.startTurn(threadID: threadID, projectPath: updated.project.path,
                                            expectedWorkspace: workspace,
                                            prompt: ReviewPrompts.fixPrompt(for: updated, round: round),
                                            kind: .fix, selection: updated.fixSelection, speed: updated.speed)
        guard let current = matchingLoop(updated.id) else { return }
        updated = current
        updated.rounds[updated.rounds.count - 1].fixTurnID = id
        try persist(updated)
    }

    private func reconcileFixResult(
        thread: ReviewThreadState, loop: ReviewLoop, round: ReviewRound,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        var updated = loop
        guard let report = round.review, !report.findings(upTo: updated.priorityLimit).isEmpty else {
            throw ReviewLoopError("The review has no findings to fix.")
        }
        let sourceFixTurn = round.fixVerification.flatMap { verification in
            thread.turns.first { $0.id == verification.sourceFixTurnID }
        } ?? (round.fixVerification == nil ? thread.turns.last : nil)
        guard let fixTurn = sourceFixTurn,
              round.fixVerification != nil || (round.allowsFollowUpTurns && thread.turns.count >= 2) ||
                (thread.turns.count == 2 && (round.fixTurnID == nil || round.fixTurnID == fixTurn.id)) else {
            throw ReviewLoopError("The fix prompt was not acknowledged. Inspect the chat; it will not be sent twice.")
        }
        if fixTurn.status == .inProgress { return }
        try requireCompleted(fixTurn)
        if try await waitForExtensionReload(fixTurn, loop: updated, using: driver, threads: threads, threadID: threadID) { return }
        let fixReport = try ReviewReportContract.fix(fixTurn.finalMessage, workspaceKind: updated.workspaceKind ?? .git)
        let result = fixReport.result
        guard result.outcome != .blocked else { throw ReviewLoopError("Fixes need attention: \(result.summary)") }
        try ReviewFixCheckpoint.validateFindings(fixReport, against: report, priorityLimit: updated.priorityLimit)
        if updated.workspaceKind == .folder {
            let workspace = try await validateWorkspace(using: driver, loop: updated, threads: threads, threadID: threadID)
            if result.outcome == .withdrawn {
                guard workspace.revision == round.baseRevision else {
                    throw ReviewLoopError("Files changed although all findings were withdrawn. Inspect the changes before resuming.")
                }
            } else {
                guard workspace.revision != round.baseRevision else {
                    throw ReviewLoopError("The fix report claims changes, but the folder files are unchanged.")
                }
            }
            try finalizeRound(loopID: updated.id, result: result, fixCommit: nil,
                            workspace: workspace, fixTurnID: fixTurn.id)
            return
        }
        let reportedCommit: String
        if result.outcome == .fixed {
            guard let fixCommit = result.fixCommit else { throw ReviewLoopError("The fix report is missing its commit.") }
            reportedCommit = try await inspectGitProcess { try await driver.resolveCommit(fixCommit, at: updated.project.path) }
        } else {
            reportedCommit = round.baseRevision
        }
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        let workspace = try await validateWorkspace(using: driver, loop: updated, threads: threads, threadID: threadID)
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        try await inspectGitProcess {
            try await ReviewFixCheckpoint.validateCommit(
                reportedCommit, result: result, baseRevision: round.baseRevision,
                workspace: workspace, at: updated.project.path, using: driver)
        }
        if workspace.revision != reportedCommit || round.fixVerification != nil {
            guard try await verifyAdvancedCheckout(thread: thread, loop: updated, round: round, sourceFixTurnID: fixTurn.id,
                                                  workspace: workspace, using: driver, threads: threads, threadID: threadID) else { return }
        }
        guard let current = activeLoop(matching: updated.id, phase: .running) else { return }
        updated = current
        guard try await publishFixIfNeeded(
            loop: updated, round: round, result: result, reportedCommit: reportedCommit,
            sourceFixTurnID: fixTurn.id, workspace: workspace, using: driver, threadID: threadID
        ) else { return }
        try finalizeRound(loopID: updated.id, result: result,
                        fixCommit: result.outcome == .fixed ? reportedCommit : nil,
                        workspace: workspace, fixTurnID: fixTurn.id)
    }

    /// Persists publication intent and schedules verification if reconciliation advances HEAD.
    private func publishFixIfNeeded(
        loop: ReviewLoop, round: ReviewRound, result: ReviewRoundResult, reportedCommit: String,
        sourceFixTurnID: String, workspace: ReviewWorkspaceState,
        using driver: any ReviewLoopDriving, threadID: String
    ) async throws -> Bool {
        guard workspace.kind == .git, result.outcome == .fixed, loop.pushToRemote else { return true }
        var updated = loop
        updated.message = "Fixes committed. Reconciling remote changes and publishing the verified fixes."
        try persist(updated)
        let publication = try await driver.reconcileAndPublishFix(
            reportedCommit, at: updated.project.path, expectedWorkspace: workspace)
        if case .verificationRequired(let workspace) = publication {
            try await submitFixVerification(loop: updated, round: round, sourceFixTurnID: sourceFixTurnID,
                                            workspace: workspace, using: driver, threadID: threadID)
            return false
        }
        return true
    }

    private func finalizeRound(
        loopID: UUID, result: ReviewRoundResult, fixCommit: String?,
        workspace: ReviewWorkspaceState, fixTurnID: String
    ) throws {
        guard var updated = activeLoop(matching: loopID, phase: .running) else { return }
        let completion = workspace.kind == .folder ? "Fixes applied and verified." : "Fixes committed."
        if result.outcome == .withdrawn {
            updated.phase = .completed
            updated.message = workspace.kind == .folder ? "All review findings were withdrawn. Files were left unchanged." : "All review findings were withdrawn. No fix commit was needed."
        } else if updated.completedRoundCount + 1 >= updated.maxRounds {
            updated.phase = .limitReached
            updated.message = "All configured review rounds completed."
        } else if updated.pauseRequested {
            updated.phase = .paused
            updated.message = completion + " Paused before the next review."
        } else {
            updated.phase = .waiting
            updated.message = completion + " Ready for a fresh review."
        }
        if result.outcome == .fixed, updated.pushToRemote { updated.message += " Fixes pushed to remote." }
        if let fixCommit, workspace.revision != fixCommit {
            updated.message += " The fixes were reverified at the current HEAD."
        }
        updated.rounds[updated.rounds.count - 1].fixTurnID = fixTurnID
        updated.rounds[updated.rounds.count - 1].result = ReviewRoundResult(
            outcome: result.outcome, addressedFindingCount: result.addressedFindingCount,
            fixCommit: fixCommit,
            summary: result.summary, verifiedRevision: workspace.revision)
        updated.expectedRevision = workspace.revision
        try persist(updated)
    }

    private func verifyAdvancedCheckout(
        thread: ReviewThreadState, loop: ReviewLoop, round: ReviewRound, sourceFixTurnID: String,
        workspace: ReviewWorkspaceState, using driver: any ReviewLoopDriving,
        threads: [RendererThread], threadID: String
    ) async throws -> Bool {
        let currentWorkspace = try await validateWorkspace(using: driver, loop: loop, threads: threads, threadID: threadID)
        guard currentWorkspace == workspace else { return false }
        if let verification = round.fixVerification {
            guard let turnID = verification.turnID, let turn = thread.turns.last, turn.id == turnID else {
                throw ReviewLoopError("The fix verification turn was not acknowledged or the chat changed. Inspect its chat before resuming; it will not be sent twice.")
            }
            if turn.status == .inProgress { return false }
            try requireCompleted(turn)
            if try await waitForExtensionReload(turn, loop: loop, using: driver, threads: threads, threadID: threadID) { return false }
            if verification.targetRevision == workspace.revision {
                let report = try ReviewReportContract.review(turn.finalMessage, priorityLimit: loop.priorityLimit)
                guard report.outcome == .reviewed, report.findings.isEmpty else {
                    throw ReviewLoopError("Fix verification needs attention at the current revision: \(report.summary) "
                        + report.findings.map { "\($0.title): \($0.body)" }.joined(separator: "\n"))
                }
                return true
            }
        }
        try await submitFixVerification(loop: loop, round: round, sourceFixTurnID: sourceFixTurnID,
                                        workspace: workspace, using: driver, threadID: threadID)
        return false
    }

    private func submitFixVerification(
        loop: ReviewLoop, round: ReviewRound, sourceFixTurnID: String, workspace: ReviewWorkspaceState,
        using driver: any ReviewLoopDriving, threadID: String
    ) async throws {
        guard var updated = activeLoop(matching: loop.id, phase: .running) else { return }
        // Persist intent before submission so a crash or lost acknowledgement cannot duplicate verification.
        updated.rounds[updated.rounds.count - 1].fixVerification = ReviewFixVerification(
            sourceFixTurnID: sourceFixTurnID, targetRevision: workspace.revision)
        updated.rounds[updated.rounds.count - 1].allowsFollowUpTurns = true
        updated.rounds[updated.rounds.count - 1].extensionReloadContinuationPending = false
        updated.message = "The branch advanced after the fix. Verifying the original findings at the current HEAD before completing this round."
        try persist(updated)
        let turnID = try await driver.startTurn(
            threadID: threadID, projectPath: updated.project.path, expectedWorkspace: workspace,
            prompt: ReviewPrompts.verifyFix(for: updated, round: round, targetRevision: workspace.revision),
            kind: .review(updated.priorityLimit), selection: updated.reviewSelection, speed: updated.speed)
        guard var current = matchingLoop(loop.id) else { return }
        current.rounds[current.rounds.count - 1].fixVerification?.turnID = turnID
        try persist(current)
    }

    private func waitForExtensionReload(
        _ turn: ReviewTurnState, loop: ReviewLoop, using driver: any ReviewLoopDriving,
        threads: [RendererThread], threadID: String
    ) async throws -> Bool {
        guard let instructions = try ReviewReportContract.extensionReloadRequest(turn.finalMessage) else { return false }
        guard let round = loop.rounds.last else { throw ReviewLoopError("Missing review round.") }
        _ = try await validateWorkspace(using: driver, loop: loop, threads: threads, threadID: threadID,
                                       policy: continuationWorkspacePolicy(for: round))
        guard var updated = activeLoop(matching: loop.id, phase: .running) else { return true }
        updated.phase = .awaitingExtensionReload
        updated.message = instructions
        try persist(updated)
        return true
    }

    private func continueInterruptedTurn(
        loop: ReviewLoop, round: ReviewRound,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        let workspace = try await validateWorkspace(using: driver, loop: loop, threads: threads, threadID: threadID,
                                              policy: continuationWorkspacePolicy(for: round))
        try await submitContinuation(loop: loop, round: round, workspace: workspace,
                                     reason: .interrupted, using: driver, threadID: threadID)
    }

    private func continueAfterExtensionReload(
        loop: ReviewLoop, round: ReviewRound, thread: ReviewThreadState,
        using driver: any ReviewLoopDriving, threads: [RendererThread], threadID: String
    ) async throws {
        guard let latest = thread.turns.last, latest.status == .completed,
              try ReviewReportContract.extensionReloadRequest(latest.finalMessage) != nil else {
            throw ReviewLoopError("The chat changed while waiting for extension reload. Inspect its chat before resuming.")
        }
        if let verification = round.fixVerification {
            let workspace = try await validateWorkspace(using: driver, loop: loop, threads: threads, threadID: threadID)
            try await submitFixVerification(loop: loop, round: round, sourceFixTurnID: verification.sourceFixTurnID,
                                            workspace: workspace, using: driver, threadID: threadID)
            return
        }
        let workspace = try await validateWorkspace(using: driver, loop: loop, threads: threads, threadID: threadID,
                                              policy: continuationWorkspacePolicy(for: round))
        try await submitContinuation(loop: loop, round: round, workspace: workspace,
                                     reason: .extensionReload, using: driver, threadID: threadID)
    }

    private enum ContinuationReason { case interrupted, extensionReload }

    private func submitContinuation(
        loop: ReviewLoop, round: ReviewRound, workspace: ReviewWorkspaceState,
        reason: ContinuationReason, using driver: any ReviewLoopDriving, threadID: String
    ) async throws {
        guard var updated = activeLoop(matching: loop.id, phase: .running) else { return }
        let prompt: String
        switch reason {
        case .interrupted:
            updated.message = "Continuing the interrupted \(round.fixRequested ? "fix task" : "review") in its existing chat."
            prompt = ReviewPrompts.interruptedContinuation(for: updated, round: round)
        case .extensionReload:
            updated.rounds[updated.rounds.count - 1].extensionReloadContinuationPending = false
            updated.message = "Continuing after the manual extension reload."
            prompt = ReviewPrompts.extensionReloadContinuation(for: updated, round: round)
        }
        // Persist intent before submission; polling must never repeat an unknown launch.
        updated.rounds[updated.rounds.count - 1].allowsFollowUpTurns = true
        try persist(updated)
        let turnID = try await driver.startTurn(
            threadID: threadID, projectPath: updated.project.path, expectedWorkspace: workspace,
            prompt: prompt,
            kind: round.fixRequested ? .fixContinuation : .review(updated.priorityLimit),
            selection: round.fixRequested ? updated.fixSelection : updated.reviewSelection, speed: updated.speed)
        guard var current = matchingLoop(loop.id) else { return }
        if round.fixRequested { current.rounds[current.rounds.count - 1].fixTurnID = turnID }
        else { current.rounds[current.rounds.count - 1].reviewTurnID = turnID }
        try persist(current)
    }

    private enum WorkspacePolicy {
        case clean
        case unchangedReview(baseRevision: String)
        case unfinishedFix
    }

    private func continuationWorkspacePolicy(for round: ReviewRound) -> WorkspacePolicy {
        if round.fixVerification != nil { return .clean }
        return round.fixRequested ? .unfinishedFix : .unchangedReview(baseRevision: round.baseRevision)
    }

    private func validateWorkspace(
        using driver: any ReviewLoopDriving, loop: ReviewLoop,
        threads: [RendererThread], threadID: String, policy: WorkspacePolicy = .clean
    ) async throws -> ReviewWorkspaceState {
        let workspace = try await inspect { try await driver.workspace(at: loop.project.path) }
        guard !hasOtherRunningTask(threads, root: workspace.root, excluding: threadID) else {
            throw ReviewLoopError("Another chat is running in this workspace. Inspect its changes before continuing.")
        }
        guard workspace.kind == loop.workspaceKind,
              workspace.git == nil || workspace.git?.branch == loop.branch,
              FileSystemPath.canonicalPath(workspace.root) == loop.workspaceRoot else {
            throw ReviewLoopError(workspace.kind == .git && loop.workspaceKind == .git
                ? "The Git checkout changed. Restore the original checkout and branch before continuing."
                : "The workspace changed. Restore the original project folder and review mode before continuing.")
        }
        switch policy {
        case .clean:
            guard workspace.git?.isClean != false else {
                throw ReviewLoopError("Commit checkpoint failed: the checkout must be clean and on the original branch.")
            }
        case .unchangedReview(let baseRevision):
            guard workspace.git?.isClean != false else {
                throw ReviewLoopError("Uncommitted changes appeared during the review. The review must leave files unchanged. Inspect the changes in its chat before resuming; no fix prompt or push was sent.")
            }
            guard workspace.revision == baseRevision else {
                throw ReviewLoopError("The project changed during the read-only review. Reviews must leave files unchanged before fixes are requested.")
            }
        case .unfinishedFix:
            break // Preserve partial edits and commits while continuing the fix.
        }
        return workspace
    }

    private func requireCompleted(_ turn: ReviewTurnState) throws {
        guard turn.status == .completed else {
            throw ReviewLoopError("The chat was interrupted or failed. Select Resume to continue in the same chat once the issue is resolved.")
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
        let now = Date.now.timeIntervalSince1970
        let next = next.map { loop in
            var updated = loop
            if matchingLoop(loop.id) != loop { updated.updatedAt = now }
            return updated
        }
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

    private func pathsOverlap(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    private func hasOtherRunningTask(_ threads: [RendererThread], root: String, excluding: String?) -> Bool {
        threads.contains { thread in
            let cwd = FileSystemPath.canonicalPath(thread.checkoutPath)
            let root = FileSystemPath.canonicalPath(root)
            return thread.id != excluding && thread.runState == .running && pathsOverlap(cwd, root)
        }
    }

    var progress: [String: ReviewLoopProgress] {
        Dictionary(uniqueKeysWithValues: loops.compactMap { loop in
            ReviewLoopPresentation.progress(for: loop).map { (loop.id.uuidString, $0) }
        })
    }
}
