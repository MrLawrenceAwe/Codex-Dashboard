import AppKit
import Foundation

@MainActor
final class ReviewLoopBridge {
    private let devTools: any DevToolsServing
    private let coordinator: ReviewLoopCoordinator
    private let makeDriver: (DevToolsTarget) -> any ReviewLoopDriving
    private var choicesTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var stopTasks: [UUID: Task<Void, Never>] = [:]
    private var models: [ReviewModel] = []
    private var projects: [ReviewProject] = []
    private var lastChoicesRefresh: Date?
    private var lastAdvance: Date?
    private var acknowledgedActionID: String?
    private var actionError: String?

    var threadIDs: Set<String> { coordinator.threadIDs }

    init(
        devTools: any DevToolsServing,
        store: any ReviewLoopStoring,
        makeDriver: ((DevToolsTarget) -> any ReviewLoopDriving)? = nil
    ) {
        self.devTools = devTools
        self.makeDriver = makeDriver ?? { ReviewLoopDriver(devTools: devTools, target: $0) }
        coordinator = ReviewLoopCoordinator(store: store)
    }

    deinit {
        choicesTask?.cancel()
        advanceTask?.cancel()
        for task in stopTasks.values { task.cancel() }
    }

    // Restart/account preflights drain work before checking for active chats.
    // Normal snapshot delivery must never await remote publication or inspection.
    func waitForOperations() async {
        let tasks = [choicesTask, advanceTask].compactMap { $0 } + Array(stopTasks.values)
        for task in tasks { await task.value }
    }

    func synchronize(targets: [DevToolsTarget], threads: [RendererThread]) async throws {
        guard let target = targets.first else { return }
        let driver = makeDriver(target)
        scheduleChoicesRefresh(using: driver)
        try await handleActions(in: targets, using: driver)
        if advanceTask == nil, lastAdvance == nil || Date.now.timeIntervalSince(lastAdvance!) >= 5 {
            advanceTask = Task { [self] in
                await coordinator.advance(using: driver, threads: threads)
                lastAdvance = .now
                advanceTask = nil
            }
        }
        for window in targets { try await deliver(to: window) }
    }

    private func scheduleChoicesRefresh(using driver: any ReviewLoopDriving) {
        guard choicesTask == nil,
              lastChoicesRefresh.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        choicesTask = Task { [self] in
            defer { choicesTask = nil }
            do {
                let latestProjects = try await driver.projects()
                let latestModels = try await driver.models()
                projects = latestProjects
                models = latestModels
                lastChoicesRefresh = .now
                actionError = nil
            } catch { actionError = error.localizedDescription }
        }
    }

    private func scheduleStop(for id: UUID, using driver: any ReviewLoopDriving) {
        guard stopTasks[id] == nil else { return }
        stopTasks[id] = Task { [self] in
            defer { stopTasks[id] = nil }
            do { try await coordinator.stopRunningTask(for: id, using: driver) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func handleActions(in targets: [DevToolsTarget], using driver: any ReviewLoopDriving) async throws {
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
                            if action.kind == .stop, let id = action.loopID {
                                scheduleStop(for: id, using: driver)
                            }
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
        let root = FileSystemPath.canonicalURL(projectPath)
        let candidate = FileSystemPath.canonicalURL(
            path.hasPrefix("/") ? path : root.appendingPathComponent(path).path
        )
        guard candidate.path != root.path, FileSystemPath.contains(candidate.path, in: root.path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    private func validateSelections(in action: ReviewLoopAction) throws {
        guard [.start, .queue].contains(action.kind) else { return }
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
        let snapshot = ReviewPageSnapshot(projects: coordinator.projectChoices(for: projects), models: models,
                                         reviewTypes: ReviewType.allCases.map(ReviewTypeOption.init),
                                         loops: coordinator.loops.map { ReviewLoopDisplaySnapshot(loop: $0) },
                                         progress: coordinator.progress,
                                         error: coordinator.error ?? actionError,
                                         acknowledgedActionID: acknowledgedActionID)
        _ = try await devTools.evaluateBoolean(RendererScript.deliverReviewPageSnapshot(snapshot), in: target)
    }
}
