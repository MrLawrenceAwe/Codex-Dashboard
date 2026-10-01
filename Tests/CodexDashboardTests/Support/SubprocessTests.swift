import XCTest

@testable import CodexDashboard

final class SubprocessTests: XCTestCase {
    func testDeadlineIncludesPipesHeldOpenAfterParentExits() async throws {
        let startedAt = Date()
        do {
            _ = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "sleep 2 & exit 0"], timeout: 0.05)
            XCTFail("Expected pipe draining to time out")
        } catch {
            guard case SubprocessError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testTimeoutDoesNotWaitForDescendantsToClosePipes() async throws {
        let startedAt = Date()
        do {
            _ = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "sleep 2 & wait"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch {
            guard case SubprocessError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testCancellationDoesNotWaitForInheritedPipes() async throws {
        let startedAt = Date()
        let task = Task {
            try await Subprocess.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "sleep 2 & exit 0"], timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        }
    }

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

    func testDrainsLargeStandardOutputAndErrorWithoutBlocking() async throws {
        let byteCount = 256 * 1_024
        let result = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "head -c \(byteCount) /dev/zero; head -c \(byteCount) /dev/zero >&2",
            ],
            timeout: 2
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, byteCount)
        XCTAssertEqual(result.standardError.count, byteCount)
    }
}
