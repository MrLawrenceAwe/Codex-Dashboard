import CoreServices
import Foundation

final class RecursiveProjectChangeMonitor: @unchecked Sendable {
    private let projectPaths: Set<String>
    private let projectPathsByObservedRoot: [String: Set<String>]
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
        projectPathsByObservedRoot = pathsByObservedRoot
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
        var affectedProjectPaths: Set<String> = []
        for changedPath in changedPaths {
            affectedProjectPaths.formUnion(projectPaths(containing: Self.standardizedPath(changedPath)))
            affectedProjectPaths.formUnion(projectPaths(containing: Self.canonicalPath(changedPath)))
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

    private func projectPaths(containing changedPath: String) -> Set<String> {
        var candidate = changedPath
        var matches: Set<String> = []
        while true {
            matches.formUnion(projectPathsByObservedRoot[candidate] ?? [])
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            guard parent != candidate else { return matches }
            candidate = parent
        }
    }
}

