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
                try await publishSnapshot(to: targets, using: dashboardRuntime)
                setConnectionState(.dashboardMounted)
                setConnectionError(nil)
                if let action = await dashboardRuntime.consumeAccountAction() {
                    Task { await self.handleAccountAction(action) }
                }
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
        let completedThreadID = observeTaskCompletions(in: snapshot.catalog.threads)
        setThreads(snapshot.catalog.threads)
        if totalThreadCount != snapshot.catalog.totalThreadCount {
            totalThreadCount = snapshot.catalog.totalThreadCount
        }
        catalogWarning = nil
        unreadStateWarning = snapshot.unreadStateWarning
        refreshThreadDataWarning()
        lastSuccessfulRefresh = .now
        if let completedThreadID {
            Task { await self.refreshAccountUsage() }
            if foregroundOnTaskCompletion {
                codexForegrounder.foregroundCodex()
                await dashboardRuntime?.openThread(completedThreadID)
            }
        }
    }

    private func observeTaskCompletions(in updatedThreads: [ThreadSummary]) -> String? {
        let observationDate = Date()
        let latestEvents = Dictionary(uniqueKeysWithValues: updatedThreads.compactMap { thread in
            thread.latestLifecycleEvent.map { (thread.id, $0) }
        })
        let previousEvents = observedLifecycleEventsByThreadID
        let previousObservationDate = lastLifecycleObservationDate
        observedLifecycleEventsByThreadID = latestEvents
        lastLifecycleObservationDate = observationDate
        guard let previousEvents, let previousObservationDate else { return nil }

        let newCompletions = latestEvents.compactMap { threadID, event -> (threadID: String, event: ThreadLifecycleEvent)? in
            guard
                event.kind == .completed,
                previousEvents[threadID] != event,
                previousEvents[threadID] != nil || event.timestamp > previousObservationDate
            else { return nil }
            return (threadID, event)
        }
        return newCompletions.max { left, right in
            if left.event.timestamp == right.event.timestamp {
                return left.threadID < right.threadID
            }
            return left.event.timestamp < right.event.timestamp
        }?.threadID
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
