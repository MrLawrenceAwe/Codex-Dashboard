import Darwin
import CoreServices
import Foundation

private final class RecursiveProjectChangeMonitor: @unchecked Sendable {
    private let projectPaths: Set<String>
    private let action: @MainActor @Sendable (Set<String>) async -> Void
    private var stream: FSEventStreamRef?

    init(
        projectPaths: Set<String>,
        action: @escaping @MainActor @Sendable (Set<String>) async -> Void
    ) {
        self.projectPaths = projectPaths
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
        let callback: FSEventStreamCallback = { _, context, _, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<RecursiveProjectChangeMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            monitor.notifyChange()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            Array(projectPaths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
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

    private func notifyChange() {
        let projectPaths = projectPaths
        let action = action
        Task { @MainActor in await action(projectPaths) }
    }
}

@MainActor
final class DataChangeMonitor {
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
    private var catalogSignature: CatalogSignature?
    private var unreadSignature: FileSignature?
    private var dataRefreshTask: Task<Void, Never>?
    private var projectRefreshTask: Task<Void, Never>?
    private var pendingProjectPaths: Set<String> = []
    private var refreshCatalog: (@MainActor () async -> Void)?
    private var refreshUnread: (@MainActor () async -> Void)?
    private var refreshWorkingTrees: (@MainActor (Set<String>?) async -> Void)?

    func start(
        catalogURL: URL,
        unreadStateURL: URL,
        refreshCatalog: @escaping @MainActor () async -> Void,
        refreshUnread: @escaping @MainActor () async -> Void,
        refreshWorkingTrees: @escaping @MainActor (Set<String>?) async -> Void
    ) {
        stop()
        self.catalogURL = catalogURL
        self.unreadStateURL = unreadStateURL
        self.refreshCatalog = refreshCatalog
        self.refreshUnread = refreshUnread
        self.refreshWorkingTrees = refreshWorkingTrees
        catalogSignature = Self.catalogSignature(at: catalogURL)
        unreadSignature = Self.fileSignature(at: unreadStateURL)

        installDataWatches()
    }

    func updateProjectPaths(_ paths: Set<String>) {
        guard paths != watchedProjectPaths else { return }
        watchedProjectPaths = paths
        cancel(&projectWatches)
        projectChangeMonitor?.stop()
        projectChangeMonitor = nil

        var pathsByGitURL: [URL: Set<String>] = [:]
        for path in paths {
            let projectURL = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: projectURL.path) else { continue }
            if let gitURL = GitMetadataLocator.metadataURL(for: projectURL) {
                pathsByGitURL[gitURL, default: []].insert(path)
            }
        }
        let existingPaths = Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
        let projectChangeMonitor = RecursiveProjectChangeMonitor(
            projectPaths: existingPaths,
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
    }

    func stop() {
        dataRefreshTask?.cancel()
        projectRefreshTask?.cancel()
        dataRefreshTask = nil
        projectRefreshTask = nil
        pendingProjectPaths = []
        cancel(&dataWatches)
        cancel(&projectWatches)
        projectChangeMonitor?.stop()
        projectChangeMonitor = nil
        watchedProjectPaths = []
        catalogURL = nil
        unreadStateURL = nil
        catalogSignature = nil
        unreadSignature = nil
        refreshCatalog = nil
        refreshUnread = nil
        refreshWorkingTrees = nil
    }

    private func scheduleDataRefresh() {
        guard dataRefreshTask == nil else { return }
        dataRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.dataRefreshTask = nil
            await self.refreshChangedData()
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
        if changed { installDataWatches() }
    }

    private func installDataWatches() {
        cancel(&dataWatches)
        guard let catalogURL, let unreadStateURL else { return }
        let writeAheadLogURL = URL(fileURLWithPath: catalogURL.path + "-wal")
        let candidates = Set([
            catalogURL.deletingLastPathComponent(),
            unreadStateURL.deletingLastPathComponent(),
            catalogURL,
            writeAheadLogURL,
            unreadStateURL,
        ]).filter { FileManager.default.fileExists(atPath: $0.path) }
        dataWatches = candidates.compactMap { url in
            makeWatch(for: url) { [weak self] in self?.scheduleDataRefresh() }
        }
    }

    private func scheduleProjectRefresh(for paths: Set<String>) {
        pendingProjectPaths.formUnion(paths)
        guard projectRefreshTask == nil else { return }
        projectRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.projectRefreshTask = nil
            let paths = self.pendingProjectPaths
            self.pendingProjectPaths = []
            if !paths.isEmpty { await self.refreshWorkingTrees?(paths) }
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
