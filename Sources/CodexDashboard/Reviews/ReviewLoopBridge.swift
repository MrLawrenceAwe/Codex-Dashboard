import Foundation

@MainActor
final class ReviewLoopBridge {
    private let devTools: any DevToolsServing
    private let coordinator: ReviewLoopCoordinator
    private var models: [ReviewModel] = []
    private var projects: [ReviewProject] = []
    private var lastProjectRefresh: Date?
    private var lastAdvance: Date?
    private var acknowledgedActionID: String?
    private var actionError: String?

    init(devTools: any DevToolsServing, store: any ReviewLoopStoring) {
        self.devTools = devTools
        coordinator = ReviewLoopCoordinator(store: store)
    }

    func synchronize(targets: [DevToolsTarget], threads: [RendererThread]) async throws {
        guard let target = targets.first else { return }
        let driver = ReviewLoopDriver(devTools: devTools, target: target)
        if lastProjectRefresh == nil || Date.now.timeIntervalSince(lastProjectRefresh!) > 60 {
            do {
                projects = try await driver.projects()
                models = try await driver.models()
                lastProjectRefresh = .now
                actionError = nil
            } catch { actionError = error.localizedDescription }
        }
        for window in targets {
            if let serialized = try await devTools.evaluateString("window.__codexDashboard.pendingReviewAction()", in: window),
               let action = try? JSONDecoder().decode(ReviewLoopAction.self, from: Data(serialized.utf8)) {
                if action.id != acknowledgedActionID {
                    do {
                        if action.kind == "start", let selection = action.selection {
                            guard let model = models.first(where: { $0.model == selection.model }),
                                  selection.effort == nil || model.efforts.contains(selection.effort!) else {
                                throw ReviewLoopError("Choose an available model and supported reasoning effort.")
                            }
                        }
                        try coordinator.apply(action, projects: projects)
                        actionError = nil
                    }
                    catch { actionError = error.localizedDescription }
                    acknowledgedActionID = action.id
                    lastAdvance = nil
                }
                // Acknowledge each window before the next window can submit another action.
                try await deliver(to: window)
            }
        }
        if lastAdvance == nil || Date.now.timeIntervalSince(lastAdvance!) >= 5 {
            await coordinator.advance(using: driver, threads: threads)
            lastAdvance = .now
        }
        for window in targets { try await deliver(to: window) }
    }

    private func deliver(to target: DevToolsTarget) async throws {
        let snapshot = ReviewLoopSnapshot(projects: projects, models: models, loop: coordinator.loop,
                                         progress: coordinator.progress,
                                         error: coordinator.error ?? actionError,
                                         acknowledgedActionID: acknowledgedActionID)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        _ = try await devTools.evaluateBoolean("window.__codexDashboard.applyReviewLoop(\(json))", in: target)
    }
}
