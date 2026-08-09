import Foundation

enum ThreadRunState: String, Codable, Equatable, Sendable {
    case running
    case idle
}

enum WorkingTreeStatus: String, Codable, Equatable, Sendable {
    case notRepository
    case unavailable
    case clean
    case hasChanges
}

struct ThreadSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let projectName: String
    let projectPath: String
    let recencyTimestamp: Int64
    let isPinned: Bool
    var isUnread = false
    let model: String?
    let runState: ThreadRunState
    var workingTreeStatus: WorkingTreeStatus
}

struct ThreadCatalog: Sendable {
    let threads: [ThreadSummary]
    let totalThreadCount: Int
}

struct DashboardSnapshot: Codable, Equatable, Sendable {
    let threads: [ThreadSummary]
    let totalThreadCount: Int

    init(threads: [ThreadSummary], totalThreadCount: Int? = nil) {
        self.threads = threads
        self.totalThreadCount = totalThreadCount ?? threads.count
    }
}
