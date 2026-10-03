import Darwin
import Foundation

/// Owns the descriptor on one queue so cancellation never waits for pipe EOF,
/// including when a descendant keeps the write end open.
final class AsyncPipeReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-dashboard.pipe-reader")
    private let source: any DispatchSourceRead
    private let descriptor: Int32
    private var buffered = Data()
    private var reachedEOF = false
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Data, any Error>?

    init(handle: FileHandle) throws {
        descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    deinit { source.cancel() }

    func readChunk() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    precondition(self.continuation == nil, "Only one pipe read may be pending.")
                    self.continuation = continuation
                    self.deliver()
                }
            }
        } onCancel: { self.cancel() }
    }

    func readToEnd() async throws -> Data {
        var data = Data()
        while true {
            let chunk = try await readChunk()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }

    func cancel() {
        queue.async {
            self.failure = CancellationError()
            self.buffered.removeAll()
            self.source.cancel()
            self.deliver()
        }
    }

    private func drain() {
        guard !reachedEOF, failure == nil else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        // Yield so continuous output cannot starve cancellation.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { buffered.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 {
                reachedEOF = true
                source.cancel()
                break
            } else if errno == EAGAIN { break }
            else if errno != EINTR {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                source.cancel()
                break
            }
        }
        deliver()
    }

    private func deliver() {
        guard let continuation else { return }
        if let failure {
            self.continuation = nil
            continuation.resume(throwing: failure)
        } else if !buffered.isEmpty || reachedEOF {
            self.continuation = nil
            let chunk = buffered
            buffered = Data()
            continuation.resume(returning: chunk)
        }
    }
}
