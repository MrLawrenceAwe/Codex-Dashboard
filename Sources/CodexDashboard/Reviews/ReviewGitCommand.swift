import Foundation

/// Shared argument-based Git execution for inspection and publication.
enum ReviewGitCommand {
    static func output(_ arguments: [String], at path: String) async throws -> String {
        let result = try await run(arguments, at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Git checkpoint failed: " + String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ arguments: [String], at path: String, timeout: TimeInterval = 5) async throws -> SubprocessOutput {
        try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--no-optional-locks", "-C", path] + arguments, timeout: timeout)
    }
}
