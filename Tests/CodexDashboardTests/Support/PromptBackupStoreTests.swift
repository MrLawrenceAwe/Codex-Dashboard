import Foundation
import XCTest

@testable import CodexDashboard

final class PromptBackupStoreTests: XCTestCase {
    func testRoundTripsValidPromptLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-prompt-backup-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptBackupStore(backupURL: directory.appendingPathComponent("prompts.json"))
        let library = #"{"prompts":[{"id":"one","name":"Review","content":"Review this"}],"sections":["General"]}"#

        let wasSaved = try await store.save(library)

        let restored = await store.load()
        XCTAssertTrue(wasSaved)
        XCTAssertEqual(restored, library)
    }

    func testDoesNotRewriteUnchangedPromptLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-prompt-backup-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptBackupStore(backupURL: directory.appendingPathComponent("prompts.json"))
        let library = #"{"prompts":[],"sections":[]}"#

        let initialSave = try await store.save(library)
        let repeatedSave = try await store.save(library)
        XCTAssertTrue(initialSave)
        XCTAssertFalse(repeatedSave)
    }

    func testRejectsNonObjectBackup() async {
        let store = PromptBackupStore(
            backupURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-dashboard-invalid-backup-\(UUID().uuidString).json")
        )

        do {
            try await store.save("[]")
            XCTFail("Expected a non-object prompt library to be rejected")
        } catch DashboardError.invalidPromptLibrary {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
