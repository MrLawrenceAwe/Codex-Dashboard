import Darwin
import Foundation

/// Serializes lifecycle changes across the menu app and command-line entry points.
final class ManagedChatLease {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static func acquire(_ root: URL) async throws -> ManagedChatLease {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            guard try manager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ManagedChatError.ownership
            }
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(root.appendingPathComponent("lifecycle.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ManagedChatError.ownership }
        do {
            for _ in 0..<300 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return ManagedChatLease(descriptor: descriptor) }
                guard errno == EWOULDBLOCK else { throw ManagedChatError.ownership }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ManagedChatError.busy
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
