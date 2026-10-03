import XCTest
@testable import CodexDashboard

final class CodexAppServerSessionTests: XCTestCase {
    func testTimeoutDoesNotWaitForDescendantHoldingOutputPipe() async throws {
        let session = try makeSessionWithInheritedPipe()
        defer { session.terminate() }
        let startedAt = Date()
        do {
            _ = try await session.request(id: 1, method: "probe", timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertNotNil(error as? CodexAccountUsageError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(session.isRunning)
    }

    func testCancellationDoesNotWaitForDescendantHoldingOutputPipe() async throws {
        let session = try makeSessionWithInheritedPipe()
        defer { session.terminate() }
        let request = Task { try await session.request(id: 1, method: "probe", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        let startedAt = Date()
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(session.isRunning)
    }

    private func makeSessionWithInheritedPipe() throws -> CodexAppServerSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DashboardPipeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-server")
        // The child inherits stdout and ignores TERM. Killing the parent cannot
        // close the read pipe; the reader must cancel independently.
        let script = """
        #!/bin/sh
        trap '' TERM
        sleep 3 &
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return try CodexAppServerSession(executableURL: executable, codexHomeURL: directory)
    }
}
