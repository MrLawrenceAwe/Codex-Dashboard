import Darwin
import Foundation

@MainActor
final class DashboardFileChangeMonitor {
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

        var pathsByGitURL: [URL: Set<String>] = [:]
        for path in paths {
            let projectURL = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: projectURL.path) else { continue }
            if let watch = makeWatch(for: projectURL, action: { [weak self] in
                self?.scheduleProjectRefresh(for: [path])
            }) {
                projectWatches.append(watch)
            }

            if let gitURL = Self.gitMetadataURL(for: projectURL) {
                pathsByGitURL[gitURL, default: []].insert(path)
            }
        }
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

    private static func gitMetadataURL(for projectURL: URL) -> URL? {
        var candidate = projectURL.standardizedFileURL
        while true {
            let gitURL = candidate.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitURL.path) { return gitURL }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
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
