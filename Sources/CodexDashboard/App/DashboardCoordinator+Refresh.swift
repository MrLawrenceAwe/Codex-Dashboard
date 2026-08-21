import Foundation

extension DashboardCoordinator {
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
        if rendererTargetCount != targets.count { rendererTargetCount = targets.count }
        guard !Task.isCancelled, !isPerformingAction else { return }

        if compatibilityWasTriggeredByUpdate && isCheckingCompatibility {
            setConnectionState(targets.isEmpty ? .codexRunningWithoutRenderer : .rendererReady)
            return
        }
        if let compatibilityReport, compatibilityReport.blockingCount > 0 {
            setConnectionState(targets.isEmpty ? .codexRunningWithoutRenderer : .rendererReady)
            setConnectionError(Self.incompatibleContractMessage)
            return
        }
        if dashboardRuntime.maintainsDashboard, !targets.isEmpty {
            do {
                try await dashboardRuntime.synchronizeDashboard(
                    with: DashboardSnapshotPayload(threads: threads), on: targets, forceRemount: false
                )
                setConnectionState(.dashboardMounted)
                setConnectionError(nil)
            } catch {
                guard !Task.isCancelled, dashboardRuntime.maintainsDashboard else { return }
                setFailure(error, lastKnownState: .rendererReady)
            }
            return
        }
        setConnectionState(!targets.isEmpty
            ? .rendererReady
            : (codexIsRunning ? .codexRunningWithoutRenderer : .codexClosed))
        setConnectionError(nil)
    }

    func refreshUnreadState() async {
        guard !isPerformingAction else { return }
        let generation = refreshGeneration
        let refresh = await threadSnapshotService.updateUnreadState()
        guard !isPerformingAction, generation == refreshGeneration else { return }
        unreadStateWarning = refresh.warning
        refreshThreadDataWarning()
        guard let unreadThreadIDs = refresh.unreadThreadIDs else { return }
        setThreads(threads.map { thread in
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
        setThreads(threads.map { thread in
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
        setThreads(snapshot.catalog.threads)
        if totalThreadCount != snapshot.catalog.totalThreadCount {
            totalThreadCount = snapshot.catalog.totalThreadCount
        }
        catalogWarning = nil
        unreadStateWarning = snapshot.unreadStateWarning
        refreshThreadDataWarning()
        lastSuccessfulRefresh = .now
    }

    private func publishSnapshotIfMaintained() async {
        guard !Task.isCancelled, !isPerformingAction, let dashboardRuntime, dashboardRuntime.maintainsDashboard else { return }
        let targets = await dashboardRuntime.rendererTargets()
        guard !Task.isCancelled, !targets.isEmpty else { return }
        try? await dashboardRuntime.synchronizeDashboard(
            with: DashboardSnapshotPayload(threads: threads), on: targets, forceRemount: false
        )
    }

    private func setThreads(_ updatedThreads: [ThreadSummary]) {
        pollingController.updateProjectPaths(Set(updatedThreads.map(\.projectPath)))
        if threads != updatedThreads { threads = updatedThreads }
    }

    private func refreshThreadDataWarning() {
        let warnings = [catalogWarning, unreadStateWarning].compactMap { $0 }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        if threadDataWarning != warning { threadDataWarning = warning }
    }

    var connectionSummary: String {
        let runningCount = threads.count { $0.runState == .running }
        return "\(runningCount) running · \(totalThreadCount) available threads"
    }
}
