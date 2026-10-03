import Foundation

struct ReviewRepositoryState: Equatable, Sendable {
    let root: String
    let branch: String
    let commit: String
    let clean: Bool
}

struct ReviewTurnState: Sendable {
    let id: String
    let status: String
    let finalMessage: String?
}

struct ReviewThreadState: Sendable {
    let cwd: String
    let turns: [ReviewTurnState]
}

struct ReviewLoopError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
protocol ReviewLoopDriving: Sendable {
    func projects() async throws -> [ReviewProject]
    func repository(at path: String) async throws -> ReviewRepositoryState
    func pushCommit(at path: String, expectedRepository: ReviewRepositoryState) async throws
    func resolveCommit(_ commit: String, at path: String) async throws -> String
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool
    func createThread(project: ReviewProject, title: String, speed: ReviewSpeed) async throws -> String
    func startTurn(threadID: String, projectPath: String, expectedRepository: ReviewRepositoryState, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String
    func interruptLatestTurn(_ threadID: String) async throws
    func readThread(_ threadID: String) async throws -> ReviewThreadState
}

@MainActor
protocol ReviewLoopStoring {
    func load() throws -> [ReviewLoop]
    func save(_ loops: [ReviewLoop]) throws
}
