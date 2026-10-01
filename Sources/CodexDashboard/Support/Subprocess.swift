import Darwin
import Foundation

enum SubprocessError: LocalizedError {
    case timedOut(URL)
    case missingTerminationStatus(URL)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executableURL):
            return "\(executableURL.lastPathComponent) timed out."
        case .missingTerminationStatus(let executableURL):
            return "\(executableURL.lastPathComponent) ended without a termination status."
        }
    }
}

struct SubprocessOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

enum Subprocess {
    private enum Event: Sendable {
        case exited(Int32), output(Data), error(Data)
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> SubprocessOutput {
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let runningProcess = RunningSubprocess(process: process)
        try runningProcess.start()
        defer { runningProcess.terminate() }
        try outputPipe.fileHandleForWriting.close()
        try errorPipe.fileHandleForWriting.close()
        let outputReader = try SubprocessPipeReader(handle: outputPipe.fileHandleForReading)
        let errorReader = try SubprocessPipeReader(handle: errorPipe.fileHandleForReading)
        return try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask { .exited(await runningProcess.waitForExit()) }
            group.addTask { .output(try await outputReader.read()) }
            group.addTask { .error(try await errorReader.read()) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SubprocessError.timedOut(executableURL)
            }
            defer {
                group.cancelAll()
                runningProcess.terminate()
                outputReader.cancel()
                errorReader.cancel()
            }
            var status: Int32?
            var output: Data?
            var error: Data?
            for try await event in group {
                switch event {
                case .exited(let value): status = value
                case .output(let value): output = value
                case .error(let value): error = value
                }
                if let status, let output, let error {
                    return SubprocessOutput(standardOutput: output, standardError: error,
                                            terminationStatus: status)
                }
            }
            throw SubprocessError.missingTerminationStatus(executableURL)
        }
    }
}

/// Nonblocking reads let cancellation close a pipe even when a descendant retains
/// its write end. All reader state and descriptor access belong to this queue.
private final class SubprocessPipeReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-dashboard.subprocess-pipe")
    private let source: any DispatchSourceRead
    private let descriptor: Int32
    private var data = Data()
    private var result: Result<Data, any Error>?
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

    func read() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else { self.continuation = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func drain() {
        guard result == nil else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        // Yield periodically so a continuously writing process cannot starve cancellation.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { finish(.success(data)); return }
            else if errno == EAGAIN { return }
            else if errno != EINTR {
                finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                return
            }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        source.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class RunningSubprocess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminationStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] process in
            self?.finish(with: process.terminationStatus)
        }
    }

    func start() throws {
        try process.run()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let terminationStatus {
                lock.unlock()
                continuation.resume(returning: terminationStatus)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let process = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func finish(with status: Int32) {
        lock.lock()
        guard terminationStatus == nil else {
            lock.unlock()
            return
        }
        terminationStatus = status
        let waiters = waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: status) }
    }
}
