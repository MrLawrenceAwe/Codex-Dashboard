import Foundation

struct DevToolsTarget: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let url: String?
    let webSocketDebuggerUrl: String?
}

enum TaskActivityStatus: String, Codable, Sendable {
    case running
    case recent
    case idle
}

struct DashboardTask: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let workspace: String
    let updatedAt: Int64
    let isPinned: Bool
    let model: String?
    let status: TaskActivityStatus
}

struct TaskSnapshot: Sendable {
    let tasks: [DashboardTask]
    let totalTaskCount: Int
    let warning: String?
}

struct DashboardPayload: Codable, Sendable {
    let tasks: [DashboardTask]
    let totalTaskCount: Int
}
