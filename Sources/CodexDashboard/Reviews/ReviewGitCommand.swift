import Foundation

/// Shared argument-based Git execution for inspection and publication.
enum ReviewGitCommand {
    static func output(_ arguments: [String], at path: String) async throws -> String {
        let result = try await run(arguments, at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Git checkpoint failed: " + String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var output = result.standardOutput
        if output.last == 0x0a { output.removeLast() }
        return String(decoding: output, as: UTF8.self)
    }

    static func run(_ arguments: [String], at path: String, timeout: TimeInterval = 5) async throws -> SubprocessOutput {
        try await Subprocess.run(executableURL: GitExecutable.url, arguments: ["--no-optional-locks", "-C", path] + arguments, timeout: timeout)
    }
}
