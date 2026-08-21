import Foundation
import XCTest

@testable import CodexDashboard

private actor PromptRestoreDevTools: DevToolsServing {
    private let storedLibraryIsValid: Bool
    private let restoreSucceeds: Bool
    private var evaluatedExpressions: [String] = []

    init(storedLibraryIsValid: Bool, restoreSucceeds: Bool = true) {
        self.storedLibraryIsValid = storedLibraryIsValid
        self.restoreSucceeds = restoreSucceeds
    }

    func mainRendererTargets() -> [DevToolsTarget] { [] }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        evaluatedExpressions.append(expression)
        return expression.contains("JSON.parse") ? storedLibraryIsValid : restoreSucceeds
    }

    func expressions() -> [String] { evaluatedExpressions }
}

final class PromptBackupStoreTests: XCTestCase {
    private let target = DevToolsTarget(
        id: "main",
        type: "page",
        url: "app://-/index.html",
        webSocketURL: "ws://127.0.0.1/main"
    )

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

    func testValidatesProjectPromptScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-prompt-scope-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptBackupStore(backupURL: directory.appendingPathComponent("prompts.json"))
        let validLibrary = #"{"version":2,"prompts":[{"id":"one","name":"Review","content":"Review this","scope":{"type":"project","projectPath":"/tmp/project"}}],"sections":["General"]}"#
        let invalidLibrary = #"{"version":2,"prompts":[{"id":"one","name":"Review","content":"Review this","scope":{"type":"project","projectPath":""}}],"sections":["General"]}"#

        let wasSaved = try await store.save(validLibrary)
        XCTAssertTrue(wasSaved)
        do {
            try await store.save(invalidLibrary)
            XCTFail("Expected an empty project path to be rejected")
        } catch DashboardError.invalidPromptLibrary {
            // Expected.
        }
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

    func testRejectsObjectWithoutPromptLibrarySchema() async {
        let store = PromptBackupStore(
            backupURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-dashboard-invalid-schema-\(UUID().uuidString).json")
        )

        do {
            try await store.save(#"{"unrelated":true}"#)
            XCTFail("Expected an object without the prompt-library schema to be rejected")
        } catch DashboardError.invalidPromptLibrary {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadIgnoresInvalidBackupOnDisk() async throws {
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-invalid-load-\(UUID().uuidString).json")
        try Data(#"{"prompts":"invalid","sections":[]}"#.utf8).write(to: backupURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: backupURL) }

        let restored = await PromptBackupStore(backupURL: backupURL).load()

        XCTAssertNil(restored)
    }

    @MainActor
    func testRestoresBackupWhenRendererLibraryIsInvalid() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-prompt-restore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptBackupStore(backupURL: directory.appendingPathComponent("prompts.json"))
        let library = #"{"prompts":[{"id":"one","name":"Review","content":"Keep this prompt"}],"sections":["General"]}"#
        try await store.save(library)
        let devTools = PromptRestoreDevTools(storedLibraryIsValid: false)
        let synchronizer = PromptLibraryBackupSynchronizer(
            store: store,
            contractSource: try DashboardInjectionResources.loadPromptLibraryContractSource()
        )

        try await synchronizer.restoreIfNeeded(in: target, using: devTools)

        let expressions = await devTools.expressions()
        XCTAssertEqual(expressions.count, 2)
        XCTAssertTrue(expressions[0].contains("JSON.parse"))
        XCTAssertTrue(expressions[1].contains("localStorage.setItem"))
        XCTAssertTrue(expressions[1].contains("Keep this prompt"))
    }

    @MainActor
    func testDoesNotReplaceValidRendererLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-prompt-valid-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptBackupStore(backupURL: directory.appendingPathComponent("prompts.json"))
        try await store.save(#"{"prompts":[],"sections":[]}"#)
        let devTools = PromptRestoreDevTools(storedLibraryIsValid: true)
        let synchronizer = PromptLibraryBackupSynchronizer(
            store: store,
            contractSource: try DashboardInjectionResources.loadPromptLibraryContractSource()
        )

        try await synchronizer.restoreIfNeeded(in: target, using: devTools)

        let expressions = await devTools.expressions()
        XCTAssertEqual(expressions.count, 1)
    }

    @MainActor
    func testFailedRestoreStopsMountBeforeBackupCanBeOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-prompt-failed-restore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptBackupStore(backupURL: directory.appendingPathComponent("prompts.json"))
        try await store.save(#"{"prompts":[],"sections":[]}"#)
        let devTools = PromptRestoreDevTools(storedLibraryIsValid: false, restoreSucceeds: false)
        let synchronizer = PromptLibraryBackupSynchronizer(
            store: store,
            contractSource: try DashboardInjectionResources.loadPromptLibraryContractSource()
        )

        do {
            try await synchronizer.restoreIfNeeded(in: target, using: devTools)
            XCTFail("Expected prompt restoration to fail closed")
        } catch DashboardError.enableFailed {
            // Expected.
        }
    }
}
