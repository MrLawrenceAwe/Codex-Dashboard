import AppKit
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

    var threadIDs: Set<String> { coordinator.threadIDs }

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
                        if action.kind == .openFile {
                            try openFile(for: action)
                        } else {
                            try validateSelections(in: action)
                            try coordinator.apply(action, projects: projects)
                        }
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

    private func openFile(for action: ReviewLoopAction) throws {
        guard let loopID = action.loopID,
              let loop = coordinator.loops.first(where: { $0.id == loopID }),
              let filePath = action.filePath,
              let url = Self.reviewFileURL(filePath, projectPath: loop.project.path) else {
            throw ReviewLoopError("This review file link is unavailable.")
        }
        guard NSWorkspace.shared.open(url) else {
            throw ReviewLoopError("The review file could not be opened.")
        }
    }

    static func reviewFileURL(_ link: String, projectPath: String) -> URL? {
        var path: String
        if link.hasPrefix("file://") {
            guard let url = URL(string: link), url.isFileURL else { return nil }
            path = url.path
        } else {
            path = link.removingPercentEncoding ?? link
        }
        if let line = path.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            path.removeSubrange(line)
        }
        let root = URL(fileURLWithPath: projectPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    private func validateSelections(in action: ReviewLoopAction) throws {
        guard action.kind == .start else { return }
        guard let reviewSelection = action.reviewSelection, let fixSelection = action.fixSelection else {
            throw ReviewLoopError("Choose a review model and a fix model before starting a loop.")
        }
        for selection in [reviewSelection, fixSelection] {
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
