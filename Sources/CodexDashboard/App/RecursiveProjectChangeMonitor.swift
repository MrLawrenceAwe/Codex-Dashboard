import CoreServices
import Foundation

final class RecursiveProjectChangeMonitor: @unchecked Sendable {
    private final class StreamContext {
        weak var monitor: RecursiveProjectChangeMonitor?

        init(monitor: RecursiveProjectChangeMonitor) {
            self.monitor = monitor
        }
    }

    private let projectPaths: Set<String>
    private let observedRoots: [(path: String, projectPaths: Set<String>)]
    private let action: @MainActor @Sendable (Set<String>) async -> Void
    private var stream: FSEventStreamRef?

    init(
        projectPaths: Set<String>,
        action: @escaping @MainActor @Sendable (Set<String>) async -> Void
    ) {
        self.projectPaths = projectPaths
        var pathsByObservedRoot: [String: Set<String>] = [:]
        for projectPath in projectPaths {
            pathsByObservedRoot[Self.standardizedPath(projectPath), default: []].insert(projectPath)
            pathsByObservedRoot[Self.canonicalPath(projectPath), default: []].insert(projectPath)
        }
        observedRoots = pathsByObservedRoot.map { (path: $0.key, projectPaths: $0.value) }
        self.action = action
    }

    func start() {
        guard !projectPaths.isEmpty else { return }
        let streamContext = StreamContext(monitor: self)
        var context = FSEventStreamContext(
            version: 0,
            // The stream can still invoke a callback already queued on its
            // dispatch queue after its owner starts tearing it down. Keep a
            // context alive for the stream lifetime, but only a weak reference
            // to the monitor so the stream does not form an ownership cycle.
            info: Unmanaged.passRetained(streamContext).toOpaque(),
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<StreamContext>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, context, _, eventPaths, _, _ in
            guard let context else { return }
            let streamContext = Unmanaged<StreamContext>
                .fromOpaque(context)
                .takeUnretainedValue()
            guard let monitor = streamContext.monitor else { return }
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
        // Directory-level events identify the affected project without producing
        // one callback entry for every generated file in a build or install.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagWatchRoot
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
        var affectedProjectPaths: Set<String> = []
        for changedPath in changedPaths {
            // FSEvents normally returns canonical paths for watched roots. Project roots
            // keep both canonical and standardized spellings, so matching path prefixes
            // here avoids resolving symlinks and allocating every ancestor for every
            // file event in a busy build tree.
            let normalizedPath = Self.standardizedPath(changedPath)
            for root in observedRoots where Self.contains(normalizedPath, in: root.path) {
                affectedProjectPaths.formUnion(root.projectPaths)
            }
        }
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

    private static func contains(_ changedPath: String, in rootPath: String) -> Bool {
        changedPath == rootPath
            || (rootPath == "/" ? changedPath.hasPrefix("/") : changedPath.hasPrefix(rootPath + "/"))
    }
}
