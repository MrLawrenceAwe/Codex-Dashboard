import Darwin
import Foundation

final class CodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let lifecycleLock = NSLock()
    private var terminated = false
    private var readBuffer = Data()

    var isRunning: Bool {
        lifecycleLock.withLock { !terminated && process.isRunning }
    }

    init(executableURL: URL, codexHomeURL: URL) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        process.environment = environment

        try process.run()
        try outputPipe.fileHandleForWriting.close()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
    }

    deinit { terminate() }

    func request(
        id: Int,
        method: String,
        params: [String: Any]? = nil,
        timeout: Duration
    ) async throws -> Data {
        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }
        try write(payload)
        return try await response(id: id, timeout: timeout)
    }

    func notify(method: String) throws {
        try write(["method": method])
    }

    func terminate() {
        let shouldTerminate = lifecycleLock.withLock {
            guard !terminated else { return false }
            terminated = true
            return true
        }
        guard shouldTerminate else { return }
        try? inputHandle.close()
        if process.isRunning {
            process.terminate()
            let process = process
            let identifier = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                if process.isRunning { Darwin.kill(identifier, SIGKILL) }
            }
        }
    }

    private func write(_ payload: [String: Any]) throws {
        guard isRunning else { throw CodexAccountUsageError.unavailable }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func response(id: Int, timeout: Duration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self, returning: Data.self) { group in
                group.addTask { try self.readResponse(id: id) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    self.terminate()
                    throw CodexAccountUsageError.unavailable
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else {
                    throw CodexAccountUsageError.unavailable
                }
                return response
            }
        } onCancel: {
            self.terminate()
        }
    }

    private func readResponse(id: Int) throws -> Data {
        while true {
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                guard (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw CodexAccountUsageError.server(
                        error["message"] as? String ?? "Unknown app-server error"
                    )
                }
                guard object["result"] != nil else {
                    throw CodexAccountUsageError.malformedResponse
                }
                return line
            }

            let chunk = outputHandle.availableData
            guard !chunk.isEmpty else { throw CodexAccountUsageError.unavailable }
            readBuffer.append(chunk)
        }
    }
}
