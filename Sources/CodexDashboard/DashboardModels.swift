import Foundation

struct DevToolsTarget: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let url: String?
    let webSocketDebuggerUrl: String?
}

enum ThreadActivityStatus: String, Codable, Equatable, Sendable {
    case running
    case idle
}

enum WorkspaceGitStatus: String, Codable, Equatable, Sendable {
    case notRepository
    case clean
    case modified
}

struct DashboardThread: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let workspace: String
    let workspacePath: String
    let updatedAt: Int64
    let isPinned: Bool
    let model: String?
    let status: ThreadActivityStatus
    let gitStatus: WorkspaceGitStatus
}

struct ThreadSnapshot: Sendable {
    let threads: [DashboardThread]
    let totalThreadCount: Int
}

struct DashboardPayload: Codable, Equatable, Sendable {
    let threads: [DashboardThread]
    let totalThreadCount: Int
}
