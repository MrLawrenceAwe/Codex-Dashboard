import Foundation

@MainActor
final class WorkingTreeChangeMonitor {
    static let projectRefreshQuietPeriod: Duration = .milliseconds(500)
    static let projectRefreshMaximumDelay: Duration = .seconds(2)

    private var projectWatches: [DispatchSourceFileSystemObject] = []
    private var projectChangeMonitor: RecursiveProjectChangeMonitor?
    private var watchedProjectPaths: Set<String> = []
    private let refreshDebouncer: RefreshDebouncer
    private var pendingProjectPaths: Set<String> = []
    private var refreshWorkingTrees: (@MainActor (Set<String>?) async -> Void)?

    init(
        projectRefreshQuietPeriod: Duration = WorkingTreeChangeMonitor.projectRefreshQuietPeriod,
        projectRefreshMaximumDelay: Duration = WorkingTreeChangeMonitor.projectRefreshMaximumDelay
    ) {
        refreshDebouncer = RefreshDebouncer(
            quietPeriod: projectRefreshQuietPeriod,
            maximumDelay: projectRefreshMaximumDelay
        )
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
        refreshDebouncer.cancel()
        pendingProjectPaths = []
        FileSystemWatch.cancel(&projectWatches)
        projectChangeMonitor?.stop()
        projectChangeMonitor = nil
        watchedProjectPaths = []
        refreshWorkingTrees = nil
    }

    private func scheduleProjectRefresh(for paths: Set<String>) {
        pendingProjectPaths.formUnion(paths)
        refreshDebouncer.schedule { [weak self] in
            guard let self else { return }
            let paths = self.pendingProjectPaths
            self.pendingProjectPaths = []
            if !paths.isEmpty { await self.refreshWorkingTrees?(paths) }
        }
    }
}
