import Foundation

@testable import CodexDashboard

extension ThreadSummary {
    static func fixture(
        id: String = "thread",
        title: String = "Thread",
        preview: String = "Preview",
        lastAssistantMessage: String? = nil,
        projectName: String = "Project",
        projectPath: String = "/tmp/project",
        recencyTimestamp: Int64 = 1,
        isPinned: Bool = false,
        isUnread: Bool = false,
        model: String? = nil,
        runState: ThreadRunState = .idle,
        workingTreeStatus: WorkingTreeStatus = .clean
    ) -> ThreadSummary {
        var thread = ThreadSummary(
            id: id,
            title: title,
            preview: preview,
            lastAssistantMessage: lastAssistantMessage,
            projectName: projectName,
            projectPath: projectPath,
            recencyTimestamp: recencyTimestamp,
            isPinned: isPinned,
            model: model,
            runState: runState,
            workingTreeStatus: workingTreeStatus
        )
        thread.isUnread = isUnread
        return thread
    }
}
