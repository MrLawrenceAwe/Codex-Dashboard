import Foundation

enum ThreadActivity: String, Codable, Equatable, Sendable {
    case running
    case idle
}

enum GitWorkingTreeStatus: String, Codable, Equatable, Sendable {
    case notRepository
    case unavailable
    case clean
    case hasChanges
}

struct DashboardThread: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let workspaceName: String
    let workspacePath: String
    let recencyTimestamp: Int64
    let isPinned: Bool
    var isUnread = false
    let model: String?
    let activity: ThreadActivity
    let gitWorkingTreeStatus: GitWorkingTreeStatus
}

struct ThreadSnapshot: Sendable {
    let threads: [DashboardThread]
    let availableThreadCount: Int
}

struct DashboardPayload: Codable, Equatable, Sendable {
    let threads: [DashboardThread]
}
