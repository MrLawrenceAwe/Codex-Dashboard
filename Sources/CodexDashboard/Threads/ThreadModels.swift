import Foundation

enum ThreadRunState: String, Codable, Equatable, Sendable {
    case running
    case idle
}

enum ThreadLifecycleEventKind: String, Codable, Equatable, Sendable {
    case started
    case completed
    case aborted
}

struct ThreadLifecycleEvent: Codable, Equatable, Sendable {
    let kind: ThreadLifecycleEventKind
    let timestamp: Date
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
    let recencyEpochMillis: Int64
    let isPinned: Bool
    var isUnread = false
    let model: String?
    let runState: ThreadRunState
    let latestLifecycleEvent: ThreadLifecycleEvent?
    var workingTreeStatus: WorkingTreeStatus
}

struct ThreadCatalog: Sendable {
    let threads: [ThreadSummary]
    let totalThreadCount: Int
}

struct ThreadWireModel: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let projectName: String
    let projectPath: String
    let recencyEpochMillis: Int64
    let isPinned: Bool
    let isUnread: Bool
    let model: String?
    let runState: ThreadRunState
    let latestLifecycleEventKind: ThreadLifecycleEventKind?
    let workingTreeStatus: WorkingTreeStatus

    init(_ thread: ThreadSummary) {
        id = thread.id
        title = thread.title
        preview = thread.preview
        projectName = thread.projectName
        projectPath = thread.projectPath
        recencyEpochMillis = thread.recencyEpochMillis
        isPinned = thread.isPinned
        isUnread = thread.isUnread
        model = thread.model
        runState = thread.runState
        latestLifecycleEventKind = thread.latestLifecycleEvent?.kind
        workingTreeStatus = thread.workingTreeStatus
    }
}

struct DashboardSnapshot: Codable, Equatable, Sendable {
    let threads: [ThreadWireModel]
    let accounts: [SavedAccountOption]
    let activeAccountID: String?
    let accountStatusMessage: String?

    init(
        threads: [ThreadSummary],
        accounts: [SavedAccountOption] = [],
        activeAccountID: String? = nil,
        accountStatusMessage: String? = nil
    ) {
        self.threads = threads.map(ThreadWireModel.init)
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.accountStatusMessage = accountStatusMessage
    }
}
