import Foundation

@testable import CodexDashboard

extension ThreadSummary {
    static func fixture(
        id: String = "thread",
        title: String = "Thread",
        preview: String = "Preview",
        projectName: String = "Project",
        projectPath: String = "/tmp/project",
        recencyEpochMillis: Int64 = 1,
        isPinned: Bool = false,
        isUnread: Bool = false,
        model: String? = nil,
        runState: ThreadRunState = .idle,
        latestLifecycleEvent: ThreadLifecycleEvent? = nil,
        workingTreeStatus: WorkingTreeStatus = .clean
    ) -> ThreadSummary {
        var thread = ThreadSummary(
            id: id,
            title: title,
            preview: preview,
            projectName: projectName,
            projectPath: projectPath,
            recencyEpochMillis: recencyEpochMillis,
            isPinned: isPinned,
            model: model,
            runState: runState,
            latestLifecycleEvent: latestLifecycleEvent,
            workingTreeStatus: workingTreeStatus
        )
        thread.isUnread = isUnread
        return thread
    }
}
