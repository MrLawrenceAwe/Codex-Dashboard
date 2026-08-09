import Foundation

@testable import CodexDashboard

extension ThreadSummary {
    static func fixture(
        id: String = "thread",
        title: String = "Thread",
        preview: String = "Preview",
        projectName: String = "Project",
        projectPath: String = "/tmp/project",
        sortTimestamp: Int64 = 1,
        isPinned: Bool = false,
        isUnread: Bool = false,
        model: String? = nil,
        runState: ThreadRunState = .idle,
        gitStatus: GitStatus = .clean
    ) -> ThreadSummary {
        var thread = ThreadSummary(
            id: id,
            title: title,
            preview: preview,
            projectName: projectName,
            projectPath: projectPath,
            sortTimestamp: sortTimestamp,
            isPinned: isPinned,
            model: model,
            runState: runState,
            gitStatus: gitStatus
        )
        thread.isUnread = isUnread
        return thread
    }
}
