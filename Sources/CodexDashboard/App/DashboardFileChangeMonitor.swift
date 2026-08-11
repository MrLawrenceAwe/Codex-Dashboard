import Darwin
import Foundation

@MainActor
final class DashboardFileChangeMonitor {
    private struct Watch {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private var dataWatches: [Watch] = []
    private var projectWatches: [Watch] = []
    private var watchedProjectPaths: Set<String> = []
    private var refreshCatalog: (@MainActor () async -> Void)?
    private var refreshUnread: (@MainActor () async -> Void)?
    private var refreshWorkingTrees: (@MainActor () async -> Void)?

    func start(
        catalogURL: URL,
        unreadStateURL: URL,
        refreshCatalog: @escaping @MainActor () async -> Void,
        refreshUnread: @escaping @MainActor () async -> Void,
        refreshWorkingTrees: @escaping @MainActor () async -> Void
    ) {
        stop()
        self.refreshCatalog = refreshCatalog
        self.refreshUnread = refreshUnread
        self.refreshWorkingTrees = refreshWorkingTrees
        dataWatches = [
            makeWatch(for: catalogURL.deletingLastPathComponent()) { [weak self] in
                await self?.refreshCatalog?()
            },
            makeWatch(for: unreadStateURL.deletingLastPathComponent()) { [weak self] in
                await self?.refreshUnread?()
            },
        ].compactMap { $0 }
    }

    func updateProjectPaths(_ paths: Set<String>) {
        guard paths != watchedProjectPaths else { return }
        watchedProjectPaths = paths
        cancel(&projectWatches)
        let urls = Set(paths.flatMap { path -> [URL] in
            let project = URL(fileURLWithPath: path, isDirectory: true)
            return [project, project.appendingPathComponent(".git", isDirectory: true)]
        }).filter { FileManager.default.fileExists(atPath: $0.path) }
        projectWatches = urls.compactMap { url in
            makeWatch(for: url) { [weak self] in await self?.refreshWorkingTrees?() }
        }
    }

    func stop() {
        cancel(&dataWatches)
        cancel(&projectWatches)
        watchedProjectPaths = []
        refreshCatalog = nil
        refreshUnread = nil
        refreshWorkingTrees = nil
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
