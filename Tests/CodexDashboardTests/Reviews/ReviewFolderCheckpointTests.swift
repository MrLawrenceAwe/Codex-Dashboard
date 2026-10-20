import XCTest
@testable import CodexDashboard

final class ReviewFolderCheckpointTests: XCTestCase {
    func testOrdinaryFolderTracksContentPathsPermissionsAndLinksWithoutWritingGit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = ReviewRepositoryCheckpoint()
        let empty = try await checkpoint.repository(at: root.path)
        XCTAssertEqual(empty.kind, .folder)
        let file = root.appendingPathComponent("CV.docx")
        try Data([0, 1, 255]).write(to: file)
        let initial = try await checkpoint.repository(at: root.path)
        XCTAssertNotEqual(initial.revision, empty.revision)
        let repeated = try await checkpoint.repository(at: root.path)
        XCTAssertEqual(initial, repeated)
        try Data([0, 2, 255]).write(to: file)
        let edited = try await checkpoint.repository(at: root.path)
        XCTAssertNotEqual(edited.revision, initial.revision)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("Renamed.docx"))
        let renamed = try await checkpoint.repository(at: root.path)
        XCTAssertNotEqual(renamed.revision, edited.revision)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("Renamed.docx").path)
        let permissions = try await checkpoint.repository(at: root.path)
        XCTAssertNotEqual(permissions.revision, renamed.revision)
        let link = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let linked = try await checkpoint.repository(at: root.path)
        XCTAssertNotEqual(linked.revision, permissions.revision)
        try FileManager.default.removeItem(at: link)
        let unlinked = try await checkpoint.repository(at: root.path)
        XCTAssertEqual(unlinked.revision, permissions.revision)
        try Data("Finder metadata".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        let finder = try await checkpoint.repository(at: root.path)
        XCTAssertEqual(finder.revision, permissions.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Renamed.docx"))
        let deleted = try await checkpoint.repository(at: root.path)
        XCTAssertEqual(deleted.revision, empty.revision)
    }

    func testMissingFolderAndBrokenRepositoryAreNotAccepted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let checkpoint = ReviewRepositoryCheckpoint()
        do {
            _ = try await checkpoint.repository(at: root.path)
            XCTFail("Missing folders must fail inspection")
        } catch {}
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("gitdir: /missing/review-worktree".utf8).write(to: root.appendingPathComponent(".git"))
        do {
            _ = try await checkpoint.repository(at: root.path)
            XCTFail("A broken Git worktree must not switch to folder mode")
        } catch {}
    }
}
