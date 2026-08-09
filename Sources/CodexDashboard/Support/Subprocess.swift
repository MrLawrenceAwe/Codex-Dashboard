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
        try outputPipe.fileHandleForWriting.close()
        try errorPipe.fileHandleForWriting.close()
        let outputTask = Task.detached {
            try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let errorTask = Task.detached {
            try errorPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let terminationStatus: Int32
        do {
            terminationStatus = try await withThrowingTaskGroup(
                of: Int32.self,
                returning: Int32.self
            ) { group in
                group.addTask { await runningProcess.waitForExit() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw SubprocessError.timedOut(executableURL)
                }
                defer {
                    group.cancelAll()
                    if process.isRunning { runningProcess.terminate() }
                }
                guard let status = try await group.next() else {
                    throw SubprocessError.missingTerminationStatus(executableURL)
                }
                return status
            }
        } catch {
            runningProcess.terminate()
            _ = try? await outputTask.value
            _ = try? await errorTask.value
            throw error
        }

        let standardOutput = try await outputTask.value
        let standardError = try await errorTask.value
        return SubprocessOutput(
            standardOutput: standardOutput,
            standardError: standardError,
            terminationStatus: terminationStatus
        )
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
