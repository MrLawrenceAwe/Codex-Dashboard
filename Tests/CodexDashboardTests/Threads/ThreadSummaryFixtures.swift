import Foundation

@testable import CodexDashboard

extension ThreadSummary {
    static func fixture(
        id: String = "thread",
        title: String = "Thread",
        preview: String = "Preview",
        projectName: String = "Project",
        checkoutPath: String = "/tmp/project",
        projectID: String? = nil,
        recencyEpochMillis: Int64 = 1,
        isPinned: Bool = false,
        isUnread: Bool = false,
        model: String? = nil,
        runState: ThreadRunState = .idle,
        latestLifecycleEvent: ThreadLifecycleEvent? = nil,
        projectGitStatus: ProjectGitStatus = .clean,
        canUseProjectGitActions: Bool = true
    ) -> ThreadSummary {
        var thread = ThreadSummary(
            id: id,
            title: title,
            preview: preview,
            projectName: projectName,
            checkoutPath: checkoutPath,
            recencyEpochMillis: recencyEpochMillis,
            isPinned: isPinned,
            model: model,
            runState: runState,
            latestLifecycleEvent: latestLifecycleEvent,
            projectGitStatus: projectGitStatus
        )
        thread.projectID = projectID ?? checkoutPath
        thread.projectGroupPath = checkoutPath
        thread.canUseProjectGitActions = canUseProjectGitActions
        thread.isUnread = isUnread
        return thread
    }
}
