import XCTest

@testable import CodexDashboard

final class SubprocessTests: XCTestCase {
    func testCapturesOutput() throws {
        let result = try Subprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["dashboard"],
            timeout: 1
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "dashboard\n")
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testTerminatesTimedOutProcess() throws {
        let startedAt = Date()
        XCTAssertThrowsError(
            try Subprocess.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
        ) { error in
            guard case SubprocessError.timedOut = error else {
                return XCTFail("Expected a timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }
}
