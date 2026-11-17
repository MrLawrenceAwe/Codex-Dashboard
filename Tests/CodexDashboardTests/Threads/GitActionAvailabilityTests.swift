import XCTest

@testable import CodexDashboard

private actor WorktreeIdentity {
    var value: String? = "completed files"
    func set(_ value: String?) { self.value = value }
    func load() -> String? { value }
}

final class GitActionAvailabilityTests: XCTestCase {
    func testSubmoduleCompletionEnablesActionsAndNestedEditsLatchUntilCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-submodule-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String], at directory: URL) async throws {
            let result = try await Subprocess.run(executableURL: GitExecutable.url,
                arguments: ["-C", directory.path] + arguments, timeout: 3)
            XCTAssertEqual(result.terminationStatus, 0, String(decoding: result.standardError, as: UTF8.self))
        }
        for directory in [root, root.appendingPathComponent("sub"), root.appendingPathComponent("sub/nested")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await git(["init", "--quiet"], at: directory)
            try await git(["config", "user.name", "Test"], at: directory)
            try await git(["config", "user.email", "test@example.com"], at: directory)
            try Data("first".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        }
        let sub = root.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")
        for (directory, name) in [(sub, "nested"), (root, "sub")] {
            try await git(["config", "-f", ".gitmodules", "submodule.\(name).path", name], at: directory)
            try await git(["config", "-f", ".gitmodules", "submodule.\(name).url", "../fixture"], at: directory)
        }
        for directory in [nested, sub, root] {
            try await git(["add", "."], at: directory)
            try await git(["commit", "--quiet", "-m", "Checkpoint"], at: directory)
        }
        try await git(["submodule", "absorbgitdirs"], at: root)
        let thread = ThreadSummary.fixture(checkoutPath: root.path)
        let availability = GitActionAvailability()
        let completion = ThreadLifecycleEvent(kind: .completed, timestamp: .distantPast)
        var result = await availability.apply(to: [thread], events: [thread.id: completion])
        XCTAssertFalse(result[0].gitActionsBlockedUntilCompletion)
        let original = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotNil(original)
        let file = nested.appendingPathComponent("notes.txt")
        try Data("edited".utf8).write(to: file)
        result = await availability.apply(to: [thread], events: [thread.id: completion])
        XCTAssertTrue(result[0].gitActionsBlockedUntilCompletion)
        try Data("first".utf8).write(to: file)
        result = await availability.apply(to: [thread], events: [thread.id: completion])
        XCTAssertTrue(result[0].gitActionsBlockedUntilCompletion)
        result = await availability.apply(to: [thread], events: [thread.id: .init(kind: .completed, timestamp: .now)])
        XCTAssertFalse(result[0].gitActionsBlockedUntilCompletion)
        let restored = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(original, restored)

        let untracked = nested.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: untracked)
        let added = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotNil(added)
        XCTAssertNotEqual(original, added)
        try await git(["add", "."], at: nested)
        let staged = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(added, staged)
        try await git(["commit", "--quiet", "-m", "Nested change"], at: nested)
        let committed = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotNil(committed)
        XCTAssertNotEqual(staged, committed, "The checked-out gitlink revision is part of the parent's content")
        try await git(["add", "nested"], at: sub)
        let stagedLink = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(committed, stagedLink, "Staging the gitlink does not change checked-out content")

        // An unpopulated submodule still has a stable identity from its gitlink.
        try FileManager.default.removeItem(at: sub)
        let missing = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertNotNil(missing)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let empty = await GitWorktreeFingerprint.load(at: root.path)
        XCTAssertEqual(missing, empty)
    }

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
