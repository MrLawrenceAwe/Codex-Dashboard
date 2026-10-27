import Foundation

extension ReviewLoopCoordinator {
    func startLoop(_ action: ReviewLoopAction, projects: [ReviewProject]) throws -> Bool {
        if loops.contains(where: { $0.startActionID == action.id }) { return false }
        guard let project = projects.first(where: { $0.id == action.projectID }),
              let limit = action.maxRounds, (1...20).contains(limit) else {
            throw ReviewLoopError("Choose an available local project and 1–20 rounds.")
        }
        guard let reviewSelection = action.reviewSelection, !reviewSelection.modelID.isEmpty,
              let fixSelection = action.fixSelection, !fixSelection.modelID.isEmpty else {
            throw ReviewLoopError("Choose a review model and a fix model before starting a loop.")
        }
        guard action.kind == .queue || !loops.contains(where: { !$0.phase.isFinished && sameProject($0.project, project) }) else {
            throw ReviewLoopError("This project already has an active loop. Queue another loop or stop it before starting another.")
        }
        let reviewType = action.reviewType ?? .bugs
        let promptContext = reviewType.supportsProjectContext ? action.promptContext ?? .general : .general
        let liveTesting = reviewType.supportsLiveTesting && (action.liveTesting ?? false)
        var loop = ReviewLoop(
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
            preserveUICopy: reviewType.supportsPreservingUICopy && (action.preserveUICopy ?? false),
            muteTestPlayback: liveTesting && (action.muteTestPlayback ?? false),
            pushToRemote: action.pushToRemote ?? false
        )
        if action.kind == .queue {
            loop.phase = .queued
            loop.message = "Queued. Starts after earlier loops for this project finish or are stopped."
        }
        try persist(loop)
        return true
    }

    func setMuteTestPlayback(_ action: ReviewLoopAction) throws {
        guard let id = action.loopID, var updated = matchingLoop(id),
              !updated.phase.isFinished, updated.phase != .stopping,
              updated.liveTesting, updated.reviewType.supportsLiveTesting,
              let muteTestPlayback = action.muteTestPlayback else {
            throw ReviewLoopError("Mute test playback requires an active loop with live testing enabled.")
        }
        updated.muteTestPlayback = muteTestPlayback
        try persist(updated)
    }

    func applyControlAction(_ action: ReviewLoopAction) throws -> Bool {
        guard let id = action.loopID, var updated = matchingLoop(id) else {
            throw ReviewLoopError("This review loop has changed. Refresh its controls.")
        }
        guard !updated.phase.isFinished else { return false }
        switch action.kind {
        case .stop:
            stopLoop(&updated)
        case .pause:
            guard updated.phase != .stopping, updated.phase != .queued else { return false }
            pauseLoop(&updated)
        case .resume:
            guard updated.phase != .stopping, updated.phase != .queued else { return false }
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
            guard !loops.contains(where: { $0.id != loop.id && !$0.phase.isFinished && $0.phase != .queued &&
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
                requestResume(for: loop.id)
                loop.message = "Checking the review chat and continuing interrupted work."
            } else {
                loop.phase = .waiting
                loop.message = "Checking the project before continuing."
            }
        case .paused:
            loop.pauseRequested = false
            loop.phase = loop.rounds.last.map { $0.result == nil } == true ? .running : .waiting
            if loop.phase == .running { requestResume(for: loop.id) }
            loop.message = "Checking the project before continuing."
        default:
            break
        }
    }

    func deleteHistory(_ action: ReviewLoopAction) throws {
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
}
