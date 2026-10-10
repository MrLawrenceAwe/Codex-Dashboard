import Foundation

enum ThreadRunState: String, Codable, Equatable, Sendable {
    case running
    case idle
}

enum ThreadLifecycleEventKind: String, Codable, Equatable, Sendable {
    case started
    case completed
    case aborted
    case usageLimitReached
}

struct ThreadLifecycleEvent: Codable, Equatable, Sendable {
    let kind: ThreadLifecycleEventKind
    let timestamp: Date
}

enum ProjectGitStatus: String, Codable, Equatable, Sendable {
    case notRepository
    case unavailable
    case clean
    case uncommittedChanges
    case unpushedCommits
    case uncommittedChangesAndUnpushedCommits
}

struct ThreadSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let projectName: String
    let checkoutPath: String
    let recencyEpochMillis: Int64
    let isPinned: Bool
    var isUnread = false
    let model: String?
    let runState: ThreadRunState
    let latestLifecycleEvent: ThreadLifecycleEvent?
    var projectID: String? = nil
    var projectGroupPath: String? = nil
    var canUseProjectGitActions = false
    var projectGitStatus: ProjectGitStatus

    var originatesFromChromeExtension: Bool {
        preview.contains("# Chrome tabs:\n- The user has the Chrome extension side panel open.")
    }
}

struct ThreadCatalog: Sendable {
    let threads: [ThreadSummary]
    let totalThreadCount: Int
}

struct RendererThread: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let projectName: String
    let checkoutPath: String
    let recencyEpochMillis: Int64
    let isPinned: Bool
    let isUnread: Bool
    let model: String?
    let runState: ThreadRunState
    let latestLifecycleEventKind: ThreadLifecycleEventKind?
    let projectID: String?
    let projectGroupPath: String?
    let canUseProjectGitActions: Bool
    let projectGitStatus: ProjectGitStatus

    init(_ thread: ThreadSummary) {
        id = thread.id
        title = thread.title
        preview = thread.preview
        projectName = thread.projectName
        checkoutPath = thread.checkoutPath
        recencyEpochMillis = thread.recencyEpochMillis
        isPinned = thread.isPinned
        isUnread = thread.isUnread
        model = thread.model
        runState = thread.runState
        latestLifecycleEventKind = thread.latestLifecycleEvent?.kind
        projectID = thread.projectID
        projectGroupPath = thread.projectGroupPath
        canUseProjectGitActions = thread.canUseProjectGitActions
        projectGitStatus = thread.projectGitStatus
    }
}

struct DashboardSnapshot: Codable, Equatable, Sendable {
    let threads: [RendererThread]
    let accountPopover: AccountPopoverSnapshot?

    init(threads: [ThreadSummary], accountPopover: AccountPopoverSnapshot? = nil) {
        self.threads = threads.map(RendererThread.init)
        self.accountPopover = accountPopover
    }
}
