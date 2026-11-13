import XCTest

@testable import CodexDashboard

private actor WorktreeIdentity {
    var value: String? = "completed files"
    func set(_ value: String?) { self.value = value }
    func load() -> String? { value }
}

final class GitActionAvailabilityTests: XCTestCase {
    func testEditsLatchAcrossAbortRevertAndUsageLimitUntilNormalCompletion() async {
        let identity = WorktreeIdentity()
        let availability = GitActionAvailability(fingerprint: { _ in await identity.load() })
        func blocked(_ kind: ThreadLifecycleEventKind, _ time: TimeInterval) async -> Bool {
            let thread = ThreadSummary.fixture(runState: kind == .started ? .running : .idle)
            let result = await availability.apply(to: [thread], events: [thread.id: .init(kind: kind, timestamp: Date(timeIntervalSince1970: time))])
            return result[0].gitActionsBlockedUntilCompletion
        }
        var value = await blocked(.completed, 1)
        XCTAssertFalse(value)
        value = await blocked(.started, 2)
        XCTAssertFalse(value, "A running response that has not edited files keeps the checkpoint available")
        await identity.set("new edits in an already dirty file")
        value = await blocked(.started, 2)
        XCTAssertTrue(value)
        await identity.set("completed files")
        value = await blocked(.aborted, 3)
        XCTAssertTrue(value, "Reverting and stopping must not clear the latch")
        value = await blocked(.started, 4)
        XCTAssertTrue(value)
        value = await blocked(.usageLimitReached, 5)
        XCTAssertTrue(value)
        value = await blocked(.completed, 6)
        XCTAssertFalse(value)
        value = await blocked(.started, 7)
        XCTAssertFalse(value)
    }

    func testAbortChecksForWritesBetweenTheLastRunningPollAndTheStop() async {
        let identity = WorktreeIdentity()
        let availability = GitActionAvailability(fingerprint: { _ in await identity.load() })
        let thread = ThreadSummary.fixture()
        _ = await availability.apply(to: [thread], events: [thread.id: .init(kind: .completed, timestamp: .distantPast)])
        await identity.set("late edit")
        let result = await availability.apply(to: [thread], events: [thread.id: .init(kind: .aborted, timestamp: .now)])
        XCTAssertTrue(result[0].gitActionsBlockedUntilCompletion)
    }

    func testEditsAfterCompletionAlsoBlockBeforeAnotherResponseStarts() async {
        let identity = WorktreeIdentity()
        let availability = GitActionAvailability(fingerprint: { _ in await identity.load() })
        let thread = ThreadSummary.fixture()
        let event = ThreadLifecycleEvent(kind: .completed, timestamp: .distantPast)
        _ = await availability.apply(to: [thread], events: [thread.id: event])
        await identity.set("edit after completion")
        let result = await availability.apply(to: [thread], events: [thread.id: event])
        XCTAssertTrue(result[0].gitActionsBlockedUntilCompletion)
    }

    func testMissingCheckpointAndReadFailuresWaitForACompletedCheckpoint() async {
        let identity = WorktreeIdentity()
        let availability = GitActionAvailability(fingerprint: { _ in await identity.load() })
        let thread = ThreadSummary.fixture()
        var result = await availability.apply(to: [thread], events: [thread.id: .init(kind: .started, timestamp: .distantPast)])
        XCTAssertTrue(result[0].gitActionsBlockedUntilCompletion)
        await identity.set(nil)
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: .now)
        result = await availability.apply(to: [thread], events: [thread.id: completed])
        XCTAssertTrue(result[0].gitActionsBlockedUntilCompletion)
        await identity.set("available again")
        result = await availability.apply(to: [thread], events: [thread.id: completed])
        XCTAssertFalse(result[0].gitActionsBlockedUntilCompletion)
    }

    func testFingerprintDetectsDirtyToDirtyEditsButIgnoresStagingAndCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) async throws {
            let result = try await Subprocess.run(executableURL: GitExecutable.url,
                arguments: ["-C", root.path] + arguments, timeout: 3)
            XCTAssertEqual(result.terminationStatus, 0, String(decoding: result.standardError, as: UTF8.self))
        }
        try await git(["init", "--quiet"])
        try await git(["config", "user.name", "Test"])
        try await git(["config", "user.email", "test@example.com"])
        let file = root.appendingPathComponent("notes.txt")
        try Data("first".utf8).write(to: file)
        let first = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotNil(first)
        try Data("other".utf8).write(to: file)
        let edited = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotEqual(first, edited)
        try await git(["add", "."])
        var current = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(current, edited)
        try await git(["commit", "--quiet", "-m", "Checkpoint"])
        current = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(current, edited)
        try FileManager.default.removeItem(at: file)
        let deleted = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotNil(deleted)
        XCTAssertNotEqual(deleted, edited)
        try await git(["add", "-u"])
        current = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(current, deleted)
        try await git(["commit", "--quiet", "-m", "Remove file"])
        current = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(current, deleted)
    }
}
