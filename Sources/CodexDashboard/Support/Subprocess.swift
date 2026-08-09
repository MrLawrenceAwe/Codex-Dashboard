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
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let identifier = UUID().uuidString
        let outputURL = temporaryDirectory.appendingPathComponent("codex-dashboard-\(identifier).stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("codex-dashboard-\(identifier).stderr")
        guard
            fileManager.createFile(atPath: outputURL.path, contents: nil),
            fileManager.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let runningProcess = RunningSubprocess(process: process)
        try runningProcess.start()
        let terminationStatus = try await withThrowingTaskGroup(
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

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        return SubprocessOutput(
            standardOutput: try Data(contentsOf: outputURL),
            standardError: try Data(contentsOf: errorURL),
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
