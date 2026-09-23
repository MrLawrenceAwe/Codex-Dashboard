import Darwin
import Foundation

@MainActor
enum FileSystemWatch {
    static func make(
        for url: URL,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> DispatchSourceFileSystemObject? {
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
        return source
    }

    private nonisolated static func eventHandler(
        for action: @escaping @MainActor @Sendable () async -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in await action() } }
    }

    private nonisolated static func cancelHandler(for descriptor: Int32) -> @Sendable () -> Void {
        { Darwin.close(descriptor) }
    }

    static func cancel(_ watches: inout [DispatchSourceFileSystemObject]) {
        watches.forEach { $0.cancel() }
        watches = []
    }
}
