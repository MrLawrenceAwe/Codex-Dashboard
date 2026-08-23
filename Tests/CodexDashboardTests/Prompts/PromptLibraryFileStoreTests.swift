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

    private func library(model: String) -> PromptLibraryDocument {
        PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "review",
                name: "Review",
                content: "Review this",
                section: "General",
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: SavedPromptPreset(model: model, reasoningEffort: "high", speed: "standard"),
                usePreset: true
            )],
            sections: ["General"]
        )
    }
}
