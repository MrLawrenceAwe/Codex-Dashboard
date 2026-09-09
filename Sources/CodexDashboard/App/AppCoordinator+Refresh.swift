import Foundation

extension AppCoordinator {
    func synchronizeRuntime() async {
        do {
            try await loadThreadSnapshot()
        } catch {
            catalogWarning = "Thread data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
            refreshThreadDataWarning()
        }

        guard !Task.isCancelled, !isPerformingAction, let dashboardRuntime else { return }
        let codexIsRunning = dashboardRuntime.codexIsRunning
        let targets = await dashboardRuntime.rendererTargets()
        updatePublished(\.rendererTargetCount, to: targets.count)
        guard !Task.isCancelled, !isPerformingAction else { return }

        if compatibilityWasTriggeredByUpdate && isCheckingCompatibility {
            updatePublished(
                \.connectionState,
                to: targets.isEmpty ? .codexRunningWithoutRenderer : .rendererAvailable
            )
            return
        }
        if let compatibilityReport, compatibilityReport.blockingCount > 0 {
            updatePublished(
                \.connectionState,
                to: targets.isEmpty ? .codexRunningWithoutRenderer : .rendererAvailable
            )
            updatePublished(\.connectionError, to: Self.incompatibleContractMessage)
            return
        }
        if dashboardRuntime.maintainsDashboard, !targets.isEmpty {
            do {
                try await publishSnapshot(to: targets, using: dashboardRuntime)
                updatePublished(\.connectionState, to: .dashboardMounted)
                updatePublished(\.connectionError, to: nil)
            } catch {
                guard !Task.isCancelled, dashboardRuntime.maintainsDashboard else { return }
                setFailure(
                    error,
                    lastKnownState: connectionState.dashboardIsMounted ? .dashboardMounted : .rendererAvailable
                )
            }
            return
        }
        updatePublished(
            \.connectionState,
            to: !targets.isEmpty
                ? .rendererAvailable
                : (codexIsRunning ? .codexRunningWithoutRenderer : .codexClosed)
        )
        updatePublished(\.connectionError, to: nil)
    }

    func refreshUnreadState() async {
        guard !isPerformingAction else { return }
        let generation = refreshGeneration
        let refresh = await threadSnapshotService.updateUnreadState()
        guard !isPerformingAction, generation == refreshGeneration else { return }
        unreadStateWarning = refresh.warning
        refreshThreadDataWarning()
        guard let unreadThreadIDs = refresh.unreadThreadIDs else { return }
        applyThreadSnapshot(threads.map { thread in
            var updatedThread = thread
            updatedThread.isUnread = unreadThreadIDs.contains(updatedThread.id)
            return updatedThread
        })
        // A newly unread task may be outside the loaded history. Include it now
        // rather than waiting for the next catalog poll.
        let loadedIDs = Set(threads.map(\.id))
        if !unreadThreadIDs.isSubset(of: loadedIDs) {
            await synchronizeDashboard()
        } else {
            await publishSnapshotIfMaintained()
        }
    }

    func refreshAfterActivation() async {
        await refreshUnreadState()
        await synchronizeDashboard()
        await refreshAccountUsage()
        if !refreshScheduler.hasFileChangeMonitoring {
            await updateWorkingTreeStatuses()
        }
    }

    func updateWorkingTreeStatuses(
        projectPaths: Set<String>? = nil,
        forceRefresh: Bool = false
    ) async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await synchronizeDashboard() }
        let generation = refreshGeneration
        let requestedPaths = forceRefresh ? Set(threads.map(\.projectPath)) : projectPaths
        guard let statusByProjectPath = await threadSnapshotService.updateWorkingTreeStatuses(
            in: threads, projectPaths: requestedPaths
        ) else { return }
        guard !isPerformingAction, generation == refreshGeneration else { return }
        applyThreadSnapshot(threads.map { thread in
            var updatedThread = thread
            if let status = statusByProjectPath[updatedThread.projectPath] {
                updatedThread.workingTreeStatus = status
            }
            return updatedThread
        })
        await publishSnapshotIfMaintained()
    }

    func loadThreadSnapshot() async throws {
        let snapshot = try await threadSnapshotService.loadSnapshot(codexLaunchDate: dashboardRuntime?.codexLaunchDate)
        guard !Task.isCancelled else { return }
        let completedThreadID = recordSnapshotAndFindNewestCompletion(in: snapshot.catalog.threads)
        applyThreadSnapshot(
            snapshot.catalog.threads,
            totalCount: snapshot.catalog.totalThreadCount,
            refreshedAt: .now
        )
        catalogWarning = nil
        unreadStateWarning = snapshot.unreadStateWarning
        refreshThreadDataWarning()
        if let completedThreadID {
            Task { await self.refreshAccountUsage() }
            let completedThread = snapshot.catalog.threads.first { $0.id == completedThreadID }
            if foregroundOnTaskCompletion,
               completedThread?.originatesFromChromeExtension != true,
               !typingActivityDetector.isUserTyping {
                codexForegrounder.foregroundCodex()
                await dashboardRuntime?.openThread(completedThreadID)
            }
        }
    }

    func publishSnapshotIfMaintained() async {
        guard !Task.isCancelled, !isPerformingAction, let dashboardRuntime, dashboardRuntime.maintainsDashboard else { return }
        let targets = await dashboardRuntime.rendererTargets()
        guard !Task.isCancelled, !targets.isEmpty else { return }
        try? await publishSnapshot(to: targets, using: dashboardRuntime)
    }

    private func publishSnapshot(
        to targets: [DevToolsTarget],
        using runtime: any DashboardRuntime
    ) async throws {
        try await runtime.synchronizeDashboard(
            with: dashboardSnapshotPayload(), on: targets, forceRemount: false
        )
    }

    private func refreshThreadDataWarning() {
        let warnings = [catalogWarning, unreadStateWarning].compactMap { $0 }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        updatePublished(\.threadDataWarning, to: warning)
    }

    var connectionSummary: String {
        let runningCount = threads.count { $0.runState == .running }
        return "\(runningCount) running · \(totalThreadCount) available tasks"
    }
}
