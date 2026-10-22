import Foundation

enum ReviewWorkspaceKind: String, Codable, Sendable { case git, folder }

struct ReviewWorkspaceState: Equatable, Sendable {
    let root: String
    let branch: String
    let revision: String
    let clean: Bool
    var kind: ReviewWorkspaceKind = .git
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

struct ReviewChatMissingError: LocalizedError {
    var errorDescription: String? { "The review chat was deleted or is no longer available." }
}

@MainActor
protocol ReviewLoopDriving: Sendable {
    func projects() async throws -> [ReviewProject]
    func models() async throws -> [ReviewModel]
    func workspace(at path: String) async throws -> ReviewWorkspaceState
    func reconcileAndPublishFix(_ commit: String, at path: String, expectedWorkspace: ReviewWorkspaceState) async throws -> ReviewPublicationOutcome
    func resolveCommit(_ commit: String, at path: String) async throws -> String
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool
    func createThread(project: ReviewProject, title: String, speed: ReviewSpeed) async throws -> String
    func startTurn(threadID: String, projectPath: String, expectedWorkspace: ReviewWorkspaceState, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String
    func interruptLatestTurn(_ threadID: String) async throws
    func readThread(_ threadID: String, reportTurnIDs: Set<String>) async throws -> ReviewThreadState
}

@MainActor
protocol ReviewLoopStoring {
    func load() throws -> [ReviewLoop]
    func save(_ loops: [ReviewLoop]) throws
}
