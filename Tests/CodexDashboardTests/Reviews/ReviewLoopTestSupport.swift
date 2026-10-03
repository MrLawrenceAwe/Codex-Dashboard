import XCTest
@testable import CodexDashboard

@MainActor
class ReviewLoopTestCase: XCTestCase {
    let reviewBoundary = "\n\nThis is a read-only review. Fixes will be requested in a separate follow-up after the review is accepted."
    let project = ReviewProject(id: "project", name: "Example", path: "/tmp/example")

    func startAction(id: String, kind: ReviewLoopAction.Kind, projectID: String?,
                             promptContext: ReviewPromptContext?, maxRounds: Int?, loopID: UUID?) -> ReviewLoopAction {
        var action = ReviewLoopAction(id: id, kind: kind, projectID: projectID,
                                      promptContext: promptContext, maxRounds: maxRounds, loopID: loopID)
        action.reviewSelection = ReviewModelSelection(modelID: "review-model", reasoningEffort: nil)
        action.fixSelection = ReviewModelSelection(modelID: "fix-model", reasoningEffort: nil)
        return action
    }

    func make(limit: Int = 5) throws -> (ReviewLoopCoordinator, ReviewTestStore, ReviewTestDriver) {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        try coordinator.apply(startAction(id: "start", kind: .start, projectID: project.id,
                                              promptContext: .general, maxRounds: limit, loopID: nil), projects: [project])
        return (coordinator, store, ReviewTestDriver())
    }

    func action(_ kind: ReviewLoopAction.Kind, for coordinator: ReviewLoopCoordinator) -> ReviewLoopAction {
        ReviewLoopAction(id: UUID().uuidString, kind: kind, projectID: nil, promptContext: nil, maxRounds: nil, loopID: coordinator.loops.last?.id)
    }

    func stop(_ coordinator: ReviewLoopCoordinator) {
        do { try coordinator.apply(action(.stop, for: coordinator), projects: [project]) }
        catch { XCTFail("Could not stop review loop: \(error)") }
    }
}

@MainActor
final class ReviewTestStore: ReviewLoopStoring {
    var loops: [ReviewLoop] = []
    var failSave = false
    func load() throws -> [ReviewLoop] { loops }
    func save(_ loops: [ReviewLoop]) throws {
        if failSave { throw ReviewLoopError("disk full") }
        self.loops = loops
    }
}

@MainActor
final class ReviewTestDriver: ReviewLoopDriving {
    var pushedCommits: [String] = []
    var failPush = false
    var clean = true
    var commit = "base"
    var branch = "main"
    var ancestor = true
    var resolvedCommit: String?
    var onResolveCommit: (() -> Void)?
    var failCreate = false
    var failRepository = false
    var failingPath: String?
    var repositoryRoot: String?
    var failReadThread = false
    var failStopThread = false
    var interruptedTurns: [String] = []
    var createCalls = 0
    var createdThreads: [String] = []
    var prompts: [String] = []
    var selections: [ReviewModelSelection?] = []
    var speeds: [ReviewSpeed] = []
    var thread = ReviewThreadState(cwd: "/tmp/example", turns: [])
    var onRepository: (() -> Void)?
    var onCreateThread: (() -> Void)?
    var onStartTurn: (() -> Void)?
    var onStartTurnAsync: (() async -> Void)?
    var onReadThread: (() -> Void)?
    func projects() async throws -> [ReviewProject] { [] }
    func pushCommit(at path: String, expectedRepository: ReviewRepositoryState) async throws {
        if failPush { throw ReviewLoopError("Remote push failed") }
        pushedCommits.append(expectedRepository.commit)
    }
    func repository(at path: String) async throws -> ReviewRepositoryState {
        await Task.yield()
        onRepository?()
        if failRepository || path == failingPath { throw ReviewLoopError("Git timed out") }
        return ReviewRepositoryState(root: repositoryRoot ?? path, branch: branch, commit: commit, clean: clean)
    }
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool { ancestor }
    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        onResolveCommit?()
        return resolvedCommit ?? commit
    }
    func createThread(project: ReviewProject, title: String, speed: ReviewSpeed) async throws -> String {
        speeds.append(speed)
        createCalls += 1
        if failCreate { throw ReviewLoopError("Lost response") }
        let id = "thread-\(createdThreads.count + 1)"
        createdThreads.append(id)
        thread = ReviewThreadState(cwd: "/tmp/example", turns: [])
        onCreateThread?()
        return id
    }
    func startTurn(threadID: String, projectPath: String, expectedRepository: ReviewRepositoryState,
                   prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String {
        prompts.append(prompt)
        selections.append(selection)
        speeds.append(speed)
        let id = "turn-\(prompts.count)"
        thread = ReviewThreadState(cwd: "/tmp/example", turns: thread.turns + [ReviewTurnState(id: id, status: "inProgress", finalMessage: nil)])
        onStartTurn?()
        await onStartTurnAsync?()
        return id
    }
    func interruptLatestTurn(_ threadID: String) async throws {
        if failStopThread { throw ReviewLoopError("Connection timed out") }
        guard let last = thread.turns.last, last.status == "inProgress" else { return }
        interruptedTurns.append(last.id)
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns.dropLast() + [
            ReviewTurnState(id: last.id, status: "interrupted", finalMessage: nil)
        ])
    }
    func readThread(_ threadID: String) async throws -> ReviewThreadState {
        onReadThread?()
        if failReadThread { throw ReviewLoopError("Connection timed out") }
        return thread
    }
    func review(priorities: [ReviewFinding.Priority]) {
        let findings = priorities.map { "## [\($0.rawValue)] Example issue\nEvidence and impact" }.joined(separator: "\n\n")
        finishTurn("# Review complete\n\nFindings: \(priorities.count)\n\n## Summary\nReview finished\n\n" + findings)
    }
    func reviewWithoutPriorities() {
        finishTurn("# Review complete\n\nFindings: 1\n\n## Summary\nReview finished\n\n## Simplify the layout\nEvidence and impact")
    }
    func finish(findings: Int, commit: String, withdrawn: [Int] = []) {
        if commit != "none" { self.commit = commit }
        let withdrawnList = withdrawn.isEmpty ? "none" : withdrawn.map(String.init).joined(separator: ", ")
        finishTurn("\(commit == "none" ? "# Findings withdrawn" : "# Fixes committed")\nFindings addressed: \(findings)\nFindings withdrawn: \(withdrawnList)\nCommit: `\(commit)`\n\n## Summary\nChanges committed")
    }
    func userFollowup() {
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns + [
            ReviewTurnState(id: "followup-\(thread.turns.count + 1)", status: "inProgress", finalMessage: nil)
        ])
    }
    func blockFix() {
        finishTurn("# Fixes blocked\nFindings addressed: 0\nFindings withdrawn: none\nCommit: `none`\n\n## Summary\nMissing evidence")
    }
    private func finishTurn(_ report: String) {
        let last = thread.turns.last!
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns.dropLast() + [
            ReviewTurnState(id: last.id, status: "completed", finalMessage: report)
        ])
    }
}
