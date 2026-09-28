import Foundation

@MainActor
final class ReviewLoopBridge {
    private let devTools: any DevToolsServing
    private let coordinator: ReviewLoopCoordinator
    private var models: [ReviewModel] = []
    private var projects: [ReviewProject] = []
    private var lastChoicesRefresh: Date?
    private var lastAdvance: Date?
    private var acknowledgedActionID: String?
    private var actionError: String?

    init(devTools: any DevToolsServing, store: any ReviewLoopStoring) {
        self.devTools = devTools
        coordinator = ReviewLoopCoordinator(store: store)
    }

    func advanceAndSynchronize(targets: [DevToolsTarget], threads: [RendererThread]) async throws {
        guard let target = targets.first else { return }
        let driver = ReviewLoopDriver(devTools: devTools, target: target)
        await refreshChoicesIfNeeded(using: driver)
        try await handleActions(in: targets)
        if lastAdvance == nil || Date.now.timeIntervalSince(lastAdvance!) >= 5 {
            await coordinator.advance(using: driver, threads: threads)
            lastAdvance = .now
        }
        for window in targets { try await deliver(to: window) }
    }

    private func refreshChoicesIfNeeded(using driver: ReviewLoopDriver) async {
        guard lastChoicesRefresh.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        do {
            projects = try await driver.projects()
            models = try await driver.models()
            lastChoicesRefresh = .now
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    private func handleActions(in targets: [DevToolsTarget]) async throws {
        for window in targets {
            if let serialized = try await devTools.evaluateString(RendererScript.pendingReviewAction, in: window),
               let action = try? JSONDecoder().decode(ReviewLoopAction.self, from: Data(serialized.utf8)) {
                if action.id != acknowledgedActionID {
                    do {
                        try validateSelections(in: action)
                        try coordinator.apply(action, projects: projects)
                        actionError = nil
                    } catch { actionError = error.localizedDescription }
                    acknowledgedActionID = action.id
                    lastAdvance = nil
                }
                // Acknowledge each window before the next window can submit another action.
                try await deliver(to: window)
            }
        }
    }

    private func validateSelections(in action: ReviewLoopAction) throws {
        guard action.kind == .start else { return }
        for selection in [action.reviewSelection, action.fixSelection].compactMap({ $0 }) {
            guard let model = models.first(where: { $0.modelID == selection.modelID }),
                  selection.reasoningEffort.map(model.supportedReasoningEfforts.contains) ?? true else {
                throw ReviewLoopError("Choose available review and fix models with supported reasoning efforts.")
            }
        }
    }

    private func deliver(to target: DevToolsTarget) async throws {
        let snapshot = ReviewLoopSnapshot(projects: projects, models: models,
                                         reviewTypes: ReviewFocus.allCases.map(ReviewTypeOption.init),
                                         loops: coordinator.loops,
                                         finishedLoopIDs: coordinator.loops.filter { $0.phase.isFinished }.map(\.id),
                                         progress: coordinator.progress,
                                         error: coordinator.error ?? actionError,
                                         acknowledgedActionID: acknowledgedActionID)
        _ = try await devTools.evaluateBoolean(RendererScript.deliverReviewLoop(snapshot), in: target)
    }
}
