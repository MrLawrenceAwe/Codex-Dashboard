import Darwin
import CoreServices
import Foundation

private final class RecursiveProjectChangeMonitor: @unchecked Sendable {
    private let projectPaths: Set<String>
    private let standardizedProjectPathByPath: [String: String]
    private let canonicalProjectPathByPath: [String: String]
    private let action: @MainActor @Sendable (Set<String>) async -> Void
    private var stream: FSEventStreamRef?

    init(
        projectPaths: Set<String>,
        action: @escaping @MainActor @Sendable (Set<String>) async -> Void
    ) {
        self.projectPaths = projectPaths
        standardizedProjectPathByPath = Dictionary(uniqueKeysWithValues: projectPaths.map {
            ($0, Self.standardizedPath($0))
        })
        canonicalProjectPathByPath = Dictionary(uniqueKeysWithValues: projectPaths.map {
            ($0, Self.canonicalPath($0))
        })
        self.action = action
    }

    func start() {
        guard !projectPaths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, context, _, eventPaths, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<RecursiveProjectChangeMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            let pathArray = Unmanaged<CFArray>
                .fromOpaque(eventPaths)
                .takeUnretainedValue()
            let paths = (0..<CFArrayGetCount(pathArray)).compactMap { index -> String? in
                guard let pointer = CFArrayGetValueAtIndex(pathArray, index) else { return nil }
                return Unmanaged<CFString>
                    .fromOpaque(pointer)
                    .takeUnretainedValue() as String
            }
            monitor.notifyChanges(at: paths)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            Array(projectPaths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func notifyChanges(at changedPaths: [String]) {
        let standardizedChangedPaths = changedPaths.map(Self.standardizedPath)
        let affectedProjectPaths = Set(projectPaths.filter { projectPath in
            let canonicalProjectPath = canonicalProjectPathByPath[projectPath] ?? projectPath
            let standardizedProjectPath = standardizedProjectPathByPath[projectPath] ?? projectPath
            return standardizedChangedPaths.contains { changedPath in
                Self.contains(changedPath, in: standardizedProjectPath)
                    || Self.contains(changedPath, in: canonicalProjectPath)
            }
        })
        guard !affectedProjectPaths.isEmpty else { return }
        let action = action
        Task { @MainActor in await action(affectedProjectPaths) }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func contains(_ changedPath: String, in projectPath: String) -> Bool {
        changedPath == projectPath
            || changedPath.hasPrefix(projectPath.hasSuffix("/") ? projectPath : projectPath + "/")
    }
}

@MainActor
final class FileChangeMonitor {
    static let projectRefreshQuietPeriod: Duration = .milliseconds(500)

    private struct Watch {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

    private struct CatalogSignature: Equatable {
        let database: FileSignature?
        let writeAheadLog: FileSignature?
    }

    private var dataWatches: [Watch] = []
    private var projectWatches: [Watch] = []
    private var projectChangeMonitor: RecursiveProjectChangeMonitor?
    private var watchedProjectPaths: Set<String> = []
    private var catalogURL: URL?
    private var unreadStateURL: URL?
    private var accountMetadataURL: URL?
    private var authenticationURL: URL?
    private var catalogSignature: CatalogSignature?
    private var unreadSignature: FileSignature?
    private var accountMetadataSignature: FileSignature?
    private var authenticationSignature: FileSignature?
    private var dataRefreshTask: Task<Void, Never>?
    private var dataRefreshTaskID: UUID?
    private var dataRefreshGeneration: UInt64 = 0
    private var projectRefreshTask: Task<Void, Never>?
    private var projectRefreshTaskID: UUID?
    private var projectRefreshGeneration: UInt64 = 0
    private var pendingProjectPaths: Set<String> = []
    private var refreshCatalog: (@MainActor () async -> Void)?
    private var refreshUnread: (@MainActor () async -> Void)?
    private var refreshAccounts: (@MainActor () async -> Void)?
    private var refreshWorkingTrees: (@MainActor (Set<String>?) async -> Void)?

    func start(
        catalogURL: URL,
        unreadStateURL: URL,
        accountMetadataURL: URL,
        authenticationURL: URL,
        refreshCatalog: @escaping @MainActor () async -> Void,
        refreshUnread: @escaping @MainActor () async -> Void,
        refreshAccounts: @escaping @MainActor () async -> Void,
        refreshWorkingTrees: @escaping @MainActor (Set<String>?) async -> Void
    ) {
        stop()
        self.catalogURL = catalogURL
        self.unreadStateURL = unreadStateURL
        self.accountMetadataURL = accountMetadataURL
        self.authenticationURL = authenticationURL
        self.refreshCatalog = refreshCatalog
        self.refreshUnread = refreshUnread
        self.refreshAccounts = refreshAccounts
        self.refreshWorkingTrees = refreshWorkingTrees
        catalogSignature = Self.catalogSignature(at: catalogURL)
        unreadSignature = Self.fileSignature(at: unreadStateURL)
        accountMetadataSignature = Self.fileSignature(at: accountMetadataURL)
        authenticationSignature = Self.fileSignature(at: authenticationURL)

        installDataWatches()
    }

    func updateProjectPaths(_ paths: Set<String>) {
        guard paths != watchedProjectPaths else { return }
        watchedProjectPaths = paths
        rebuildProjectWatches()
    }

    private func rebuildProjectWatches() {
        cancel(&projectWatches)
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
            if let watch = makeWatch(for: gitURL, action: { [weak self] in
                self?.scheduleProjectRefresh(for: affectedPaths)
            }) {
                projectWatches.append(watch)
            }
        }
        for path in existingPaths.subtracting(repositoryProjectPaths) {
            let projectURL = URL(fileURLWithPath: path, isDirectory: true)
            if let watch = makeWatch(for: projectURL, action: { [weak self] in
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
        dataRefreshGeneration &+= 1
        projectRefreshGeneration &+= 1
        dataRefreshTask?.cancel()
        projectRefreshTask?.cancel()
        dataRefreshTask = nil
        dataRefreshTaskID = nil
        projectRefreshTask = nil
        projectRefreshTaskID = nil
        pendingProjectPaths = []
        cancel(&dataWatches)
        cancel(&projectWatches)
        projectChangeMonitor?.stop()
        projectChangeMonitor = nil
        watchedProjectPaths = []
        catalogURL = nil
        unreadStateURL = nil
        accountMetadataURL = nil
        authenticationURL = nil
        catalogSignature = nil
        unreadSignature = nil
        accountMetadataSignature = nil
        authenticationSignature = nil
        refreshCatalog = nil
        refreshUnread = nil
        refreshAccounts = nil
        refreshWorkingTrees = nil
    }

    private func scheduleDataRefresh() {
        dataRefreshGeneration &+= 1
        guard dataRefreshTask == nil else { return }
        let taskID = UUID()
        dataRefreshTaskID = taskID
        dataRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generationBeforeQuietPeriod = self.dataRefreshGeneration
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                if self.dataRefreshGeneration != generationBeforeQuietPeriod {
                    continue
                }
                await self.refreshChangedData()
                guard !Task.isCancelled,
                      self.dataRefreshGeneration != generationBeforeQuietPeriod
                else { break }
            }
            if self.dataRefreshTaskID == taskID {
                self.dataRefreshTask = nil
                self.dataRefreshTaskID = nil
            }
        }
    }

    private func refreshChangedData() async {
        var changed = false
        if let catalogURL {
            let latest = Self.catalogSignature(at: catalogURL)
            if latest != catalogSignature {
                catalogSignature = latest
                changed = true
                await refreshCatalog?()
            }
        }
        if let unreadStateURL {
            let latest = Self.fileSignature(at: unreadStateURL)
            if latest != unreadSignature {
                unreadSignature = latest
                changed = true
                await refreshUnread?()
            }
        }
        var accountStateChanged = false
        if let accountMetadataURL {
            let latest = Self.fileSignature(at: accountMetadataURL)
            if latest != accountMetadataSignature {
                accountMetadataSignature = latest
                changed = true
                accountStateChanged = true
            }
        }
        if let authenticationURL {
            let latest = Self.fileSignature(at: authenticationURL)
            if latest != authenticationSignature {
                authenticationSignature = latest
                changed = true
                accountStateChanged = true
            }
        }
        if accountStateChanged { await refreshAccounts?() }
        if changed { installDataWatches() }
    }

    private func installDataWatches() {
        cancel(&dataWatches)
        guard
            let catalogURL,
            let unreadStateURL,
            let accountMetadataURL,
            let authenticationURL
        else { return }
        let writeAheadLogURL = URL(fileURLWithPath: catalogURL.path + "-wal")
        let candidates = Set([
            catalogURL.deletingLastPathComponent(),
            unreadStateURL.deletingLastPathComponent(),
            accountMetadataURL.deletingLastPathComponent(),
            authenticationURL.deletingLastPathComponent(),
            catalogURL,
            writeAheadLogURL,
            unreadStateURL,
            accountMetadataURL,
            authenticationURL,
        ]).filter { FileManager.default.fileExists(atPath: $0.path) }
        dataWatches = candidates.compactMap { url in
            makeWatch(for: url) { [weak self] in self?.scheduleDataRefresh() }
        }
    }

    private func scheduleProjectRefresh(for paths: Set<String>) {
        pendingProjectPaths.formUnion(paths)
        projectRefreshGeneration &+= 1
        guard projectRefreshTask == nil else { return }
        let taskID = UUID()
        projectRefreshTaskID = taskID
        projectRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generationBeforeQuietPeriod = self.projectRefreshGeneration
                try? await Task.sleep(for: Self.projectRefreshQuietPeriod)
                guard !Task.isCancelled else { break }
                if self.projectRefreshGeneration != generationBeforeQuietPeriod {
                    continue
                }
                let paths = self.pendingProjectPaths
                self.pendingProjectPaths = []
                if !paths.isEmpty { await self.refreshWorkingTrees?(paths) }
                guard !Task.isCancelled, !self.pendingProjectPaths.isEmpty else { break }
            }
            if self.projectRefreshTaskID == taskID {
                self.projectRefreshTask = nil
                self.projectRefreshTaskID = nil
            }
        }
    }

    private static func catalogSignature(at url: URL) -> CatalogSignature {
        CatalogSignature(
            database: fileSignature(at: url),
            writeAheadLog: fileSignature(at: URL(fileURLWithPath: url.path + "-wal"))
        )
    }

    private static func fileSignature(at url: URL) -> FileSignature? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        return FileSignature(size: size, modifiedAt: modifiedAt)
    }

    private func makeWatch(
        for url: URL,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> Watch? {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: Self.eventHandler(for: action))
        source.setCancelHandler(handler: Self.cancelHandler(for: descriptor))
        source.resume()
        return Watch(descriptor: descriptor, source: source)
    }

    private nonisolated static func eventHandler(
        for action: @escaping @MainActor @Sendable () async -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in await action() } }
    }

    private nonisolated static func cancelHandler(for descriptor: Int32) -> @Sendable () -> Void {
        { Darwin.close(descriptor) }
    }

    private func cancel(_ watches: inout [Watch]) {
        watches.forEach { $0.source.cancel() }
        watches = []
    }
}
