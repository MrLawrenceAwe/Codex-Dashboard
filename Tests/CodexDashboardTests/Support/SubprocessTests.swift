import XCTest

@testable import CodexDashboard

final class SubprocessTests: XCTestCase {
    func testCapturesOutput() async throws {
        let result = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["dashboard"],
            timeout: 1
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "dashboard\n")
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testTerminatesTimedOutProcess() async throws {
        let startedAt = Date()
        do {
            _ = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
            XCTFail("Expected the process to time out")
        } catch {
            guard case SubprocessError.timedOut = error else {
                return XCTFail("Expected a timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }
}
