import Foundation
import XCTest

@testable import CodexDashboard

final class PromptLibraryFileStoreTests: XCTestCase {
    func testMaxAndUltraEffortsPersistWithoutChangingSavedIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-efforts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(
            documentURL: directory.appendingPathComponent("prompt-library.json")
        )
        for effort in ["max", "ultra"] {
            let document = library(model: "gpt-5.6-sol", reasoningEffort: effort)
            XCTAssertTrue(document.isValid)
            XCTAssertTrue(try store.save(document))
            XCTAssertEqual(try store.load(), document)
        }
    }

    func testPersistsUnknownModelIdentifiersAndCreatesBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(
            documentURL: directory.appendingPathComponent("prompt-library.json"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let initial = library(model: "gpt-future")
        let updated = library(model: "gpt-future-2")

        XCTAssertTrue(try store.save(initial))
        XCTAssertTrue(try store.save(updated))

        XCTAssertEqual(try store.load(), updated)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.backupDirectoryURL.path).count,
            1
        )
    }

    func testUnreadableExistingLibraryIsNotReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("prompt-library.json")
        let store = PromptLibraryFileStore(documentURL: documentURL)
        let original = library(model: "gpt-original")
        try store.save(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documentURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: documentURL.path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: documentURL.path))
        XCTAssertThrowsError(try Data(contentsOf: documentURL))
        XCTAssertThrowsError(try store.save(library(model: "gpt-new")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupDirectoryURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: documentURL.path)
        XCTAssertEqual(try store.load(), original)
    }

    func testImportRejectsInvalidLibraryWithoutReplacingCurrentDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(
            documentURL: directory.appendingPathComponent("prompt-library.json")
        )
        let current = library(model: "gpt-current")
        try store.save(current)
        let invalidURL = directory.appendingPathComponent("invalid.json")
        try Data(#"{"version":3,"prompts":{},"sections":[]}"#.utf8).write(to: invalidURL)

        XCTAssertThrowsError(try store.importDocument(from: invalidURL))
        XCTAssertEqual(try store.load(), current)
    }

    func testImportRejectsPresetValuesUnsupportedByRenderer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-preset-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(
            documentURL: directory.appendingPathComponent("prompt-library.json")
        )
        let current = library(model: "gpt-current")
        try store.save(current)
        let invalidURL = directory.appendingPathComponent("invalid-preset.json")
        let invalid = library(model: "gpt-current", reasoningEffort: "unsupported")
        try JSONEncoder().encode(invalid).write(to: invalidURL)

        XCTAssertThrowsError(try store.importDocument(from: invalidURL))
        XCTAssertEqual(try store.load(), current)
    }

    func testRapidSavesCreateDistinctBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(
            documentURL: directory.appendingPathComponent("prompt-library.json"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        try store.save(library(model: "gpt-one"))
        try store.save(library(model: "gpt-two"))
        try store.save(library(model: "gpt-three"))

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.backupDirectoryURL.path).count,
            2
        )
    }

    func testBackupRotationPreservesUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-backup-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(
            documentURL: directory.appendingPathComponent("prompt-library.json"),
            maximumBackupCount: 1
        )
        try store.save(library(model: "gpt-one"))
        try FileManager.default.createDirectory(
            at: store.backupDirectoryURL,
            withIntermediateDirectories: true
        )
        let unrelatedURL = store.backupDirectoryURL.appendingPathComponent("keep-me.json")
        try Data("personal backup".utf8).write(to: unrelatedURL)

        try store.save(library(model: "gpt-two"))
        try store.save(library(model: "gpt-three"))

        let contents = try FileManager.default.contentsOfDirectory(
            at: store.backupDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertEqual(
            contents.filter { $0.lastPathComponent.hasPrefix("prompt-library-") }.count,
            1
        )
    }

    func testLoadMigratesLegacyLightReasoningEffortAndCreatesBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("prompt-library.json")
        let store = PromptLibraryFileStore(documentURL: documentURL)
        let legacy = library(model: "gpt-5.6-luna", reasoningEffort: "light", version: 3)
        try JSONEncoder().encode(legacy).write(to: documentURL)

        let migrated = try XCTUnwrap(store.load())

        XCTAssertEqual(migrated.prompts.first?.preset?.reasoningEffort, "low")
        XCTAssertEqual(
            try JSONDecoder().decode(
                PromptLibraryDocument.self,
                from: Data(contentsOf: documentURL)
            ).prompts.first?.preset?.reasoningEffort,
            "low"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.backupDirectoryURL.path).count,
            1
        )
    }

    private func library(model: String, reasoningEffort: String = "high", version: Int = PromptLibrarySchema.currentVersion) -> PromptLibraryDocument {
        PromptLibraryDocument(
            version: version,
            prompts: [SavedPrompt(
                id: "review",
                name: "Review",
                content: "Review this",
                section: "General",
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: SavedPromptPreset(model: model, reasoningEffort: reasoningEffort, speed: "standard"),
                usePreset: true
            )],
            sections: ["General"]
        )
    }
}
