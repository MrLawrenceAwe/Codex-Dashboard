import Foundation

@MainActor
final class WorkingTreeChangeMonitor {
    static let projectRefreshQuietPeriod: Duration = .milliseconds(500)
    static let projectRefreshMaximumDelay: Duration = .seconds(2)

    private var projectWatches: [DispatchSourceFileSystemObject] = []
    private var projectChangeMonitor: RecursiveProjectChangeMonitor?
    private var watchedProjectPaths: Set<String> = []
    private var projectRefreshTask: Task<Void, Never>?
    private var projectRefreshTaskID: UUID?
    private var projectRefreshGeneration: UInt64 = 0
    private var pendingProjectPaths: Set<String> = []
    private var refreshWorkingTrees: (@MainActor (Set<String>?) async -> Void)?
    private let projectRefreshQuietPeriod: Duration
    private let projectRefreshMaximumDelay: Duration

    init(
        projectRefreshQuietPeriod: Duration = WorkingTreeChangeMonitor.projectRefreshQuietPeriod,
        projectRefreshMaximumDelay: Duration = WorkingTreeChangeMonitor.projectRefreshMaximumDelay
    ) {
        self.projectRefreshQuietPeriod = projectRefreshQuietPeriod
        self.projectRefreshMaximumDelay = projectRefreshMaximumDelay
    }

    func start(refreshWorkingTrees: @escaping @MainActor (Set<String>?) async -> Void) {
        stop()
        self.refreshWorkingTrees = refreshWorkingTrees
    }

    func updateProjectPaths(_ paths: Set<String>) {
        guard paths != watchedProjectPaths else { return }
        watchedProjectPaths = paths
        rebuildProjectWatches()
    }

    private func rebuildProjectWatches() {
        FileSystemWatch.cancel(&projectWatches)
        projectChangeMonitor?.stop()
        projectChangeMonitor = nil

        var pathsByGitURL: [URL: Set<String>] = [:]
        for path in watchedProjectPaths {
            let projectURL = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: projectURL.path) else { continue }
            if let gitURL = GitMetadataLocator.metadataURL(for: projectURL) {
                pathsByGitURL[gitURL, default: []].insert(path)
            }

        }

        let existingPaths = Set(watchedProjectPaths.filter { FileManager.default.fileExists(atPath: $0) })
        let repositoryProjectPaths = Set(pathsByGitURL.values.flatMap { $0 })
        let projectChangeMonitor = RecursiveProjectChangeMonitor(
            projectPaths: repositoryProjectPaths,
            action: { [weak self] paths in self?.scheduleProjectRefresh(for: paths) }
        )
        projectChangeMonitor.start()
        self.projectChangeMonitor = projectChangeMonitor
        for (gitURL, affectedPaths) in pathsByGitURL {
            if let watch = FileSystemWatch.make(for: gitURL, action: { [weak self] in
                self?.scheduleProjectRefresh(for: affectedPaths)
            }) {
                projectWatches.append(watch)
            }

        }

        for path in existingPaths.subtracting(repositoryProjectPaths) {
            let projectURL = URL(fileURLWithPath: path, isDirectory: true)
            if let watch = FileSystemWatch.make(for: projectURL, action: { [weak self] in
                await self?.handleNonRepositoryProjectChange(at: path)
            }) {
                projectWatches.append(watch)
            }

        }

    }
    private func handleNonRepositoryProjectChange(at path: String) async {
        // A shallow directory watch is enough to notice a newly-created .git entry
        // without recursively observing every file in historical non-repository paths.
        rebuildProjectWatches()
        scheduleProjectRefresh(for: [path])
    }

    func stop() {
        projectRefreshGeneration &+= 1
        projectRefreshTask?.cancel()
        projectRefreshTask = nil
        projectRefreshTaskID = nil
        pendingProjectPaths = []
        FileSystemWatch.cancel(&projectWatches)
        projectChangeMonitor?.stop()
        projectChangeMonitor = nil
        watchedProjectPaths = []
        refreshWorkingTrees = nil
    }

    private func scheduleProjectRefresh(for paths: Set<String>) {
        pendingProjectPaths.formUnion(paths)
        projectRefreshGeneration &+= 1
        guard projectRefreshTask == nil else { return }
        let taskID = UUID()
        projectRefreshTaskID = taskID
        projectRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var maximumDelayDeadline = ContinuousClock.now + self.projectRefreshMaximumDelay
            while !Task.isCancelled {
                let generationBeforeQuietPeriod = self.projectRefreshGeneration
                let now = ContinuousClock.now
                if now < maximumDelayDeadline {
                    try? await Task.sleep(
                        for: min(
                            self.projectRefreshQuietPeriod,
                            now.duration(to: maximumDelayDeadline)
                        )
                    )
                }

                guard !Task.isCancelled else { break }
                if self.projectRefreshGeneration != generationBeforeQuietPeriod,
                   ContinuousClock.now < maximumDelayDeadline {
                    continue
                }

                let paths = self.pendingProjectPaths
                self.pendingProjectPaths = []
                if !paths.isEmpty { await self.refreshWorkingTrees?(paths) }
                guard !Task.isCancelled, !self.pendingProjectPaths.isEmpty else { break }
                maximumDelayDeadline = ContinuousClock.now + self.projectRefreshMaximumDelay
            }

            if self.projectRefreshTaskID == taskID {
                self.projectRefreshTask = nil
                self.projectRefreshTaskID = nil
            }

        }

    }
}
