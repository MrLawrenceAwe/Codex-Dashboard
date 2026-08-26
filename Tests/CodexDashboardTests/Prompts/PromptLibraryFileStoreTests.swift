import Foundation
import XCTest

@testable import CodexDashboard

final class PromptLibraryFileStoreTests: XCTestCase {
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

    func testLoadMigratesLegacyLowReasoningEffortAndCreatesBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("prompt-library.json")
        let store = PromptLibraryFileStore(documentURL: documentURL)
        let legacy = library(model: "gpt-5.6-luna", reasoningEffort: "low")
        try JSONEncoder().encode(legacy).write(to: documentURL)

        let migrated = try XCTUnwrap(store.load())

        XCTAssertEqual(migrated.prompts.first?.preset?.reasoningEffort, "light")
        XCTAssertEqual(
            try JSONDecoder().decode(
                PromptLibraryDocument.self,
                from: Data(contentsOf: documentURL)
            ).prompts.first?.preset?.reasoningEffort,
            "light"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.backupDirectoryURL.path).count,
            1
        )
    }

    private func library(model: String, reasoningEffort: String = "high") -> PromptLibraryDocument {
        PromptLibraryDocument(
            version: 3,
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
