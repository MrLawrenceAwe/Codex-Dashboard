import Darwin
import Foundation

enum SubprocessError: LocalizedError {
    case timedOut(URL)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executableURL):
            return "\(executableURL.lastPathComponent) timed out."
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
    ) throws -> SubprocessOutput {
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
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.terminationHandler = { _ in completion.signal() }
        try process.run()

        let deadline = DispatchTime.now() + timeout
        guard completion.wait(timeout: deadline) == .success else {
            process.terminate()
            if completion.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .seconds(1))
            }
            throw SubprocessError.timedOut(executableURL)
        }

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        return SubprocessOutput(
            standardOutput: try Data(contentsOf: outputURL),
            standardError: try Data(contentsOf: errorURL),
            terminationStatus: process.terminationStatus
        )
    }
}
