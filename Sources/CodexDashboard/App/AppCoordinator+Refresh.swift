import Foundation

extension AppCoordinator {
    func synchronizeRuntime() async {
        do {
            try await loadThreadSnapshot()
        } catch {
            setCatalogWarning("Thread data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)")
            refreshThreadDataWarning()
        }

        guard !Task.isCancelled, !isPerformingAction, let dashboardRuntime else { return }
        let codexIsRunning = dashboardRuntime.codexIsRunning
        let targets = await dashboardRuntime.rendererTargets()
        setRendererTargetCount(targets.count)
        guard !Task.isCancelled, !isPerformingAction else { return }

        if compatibilityWasTriggeredByUpdate && isCheckingCompatibility {
            setConnectionState(targets.isEmpty ? .codexRunningWithoutRenderer : .rendererAvailable)
            return
        }
        if let compatibilityReport, compatibilityReport.blockingCount > 0 {
            setConnectionState(targets.isEmpty ? .codexRunningWithoutRenderer : .rendererAvailable)
            setConnectionError(Self.incompatibleContractMessage)
            return
        }
        if dashboardRuntime.maintainsDashboard, !targets.isEmpty {
            do {
                try await publishSnapshot(to: targets, using: dashboardRuntime)
                setConnectionState(.dashboardMounted)
                setConnectionError(nil)
            } catch {
                guard !Task.isCancelled, dashboardRuntime.maintainsDashboard else { return }
                setFailure(error, lastKnownState: .rendererAvailable)
            }
            return
        }
        setConnectionState(!targets.isEmpty
            ? .rendererAvailable
            : (codexIsRunning ? .codexRunningWithoutRenderer : .codexClosed))
        setConnectionError(nil)
    }

    func refreshUnreadState() async {
        guard !isPerformingAction else { return }
        let generation = refreshGeneration
        let refresh = await threadSnapshotService.updateUnreadState()
        guard !isPerformingAction, generation == refreshGeneration else { return }
        setUnreadStateWarning(refresh.warning)
        refreshThreadDataWarning()
        guard let unreadThreadIDs = refresh.unreadThreadIDs else { return }
        setThreadSnapshot(threads.map { thread in
            var updatedThread = thread
            updatedThread.isUnread = unreadThreadIDs.contains(updatedThread.id)
            return updatedThread
        })
        await publishSnapshotIfMaintained()
    }

    func refreshAfterActivation() async {
        await synchronizeDashboard()
        await updateWorkingTreeStatuses()
    }

    func updateWorkingTreeStatuses(projectPaths: Set<String>? = nil) async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await synchronizeDashboard() }
        let generation = refreshGeneration
        guard let statusByProjectPath = await threadSnapshotService.updateWorkingTreeStatuses(
            in: threads, projectPaths: projectPaths
        ) else { return }
        guard !isPerformingAction, generation == refreshGeneration else { return }
        setThreadSnapshot(threads.map { thread in
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
        let completedThreadID = newestCompletedThreadID(in: snapshot.catalog.threads)
        setThreadSnapshot(
            snapshot.catalog.threads,
            totalCount: snapshot.catalog.totalThreadCount,
            refreshedAt: .now
        )
        setCatalogWarning(nil)
        setUnreadStateWarning(snapshot.unreadStateWarning)
        refreshThreadDataWarning()
        if let completedThreadID {
            Task { await self.refreshAccountUsage() }
            if foregroundOnTaskCompletion {
                codexForegrounder.foregroundCodex()
                await dashboardRuntime?.openThread(completedThreadID)
            }
        }
    }

    private func publishSnapshotIfMaintained() async {
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
        setThreadDataWarning(warning)
    }

    var connectionSummary: String {
        let runningCount = threads.count { $0.runState == .running }
        return "\(runningCount) running · \(totalThreadCount) available threads"
    }
}
