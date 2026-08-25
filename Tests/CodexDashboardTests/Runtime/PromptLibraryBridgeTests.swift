import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension DashboardRendererTests {
    func testPromptLibraryMigratesToNativeStoreAndExternalImportWins() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let rendererLibrary = #"{"version":3,"prompts":[{"id":"old","name":"Old","content":"Old content","scope":{"type":"global"},"preset":{"model":"gpt-future"}}],"sections":[]}"#
        let devTools = PromptLibraryRendererDevTools(target: target, exportedLibrary: rendererLibrary)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            promptLibraryStore: store
        )
        let snapshot = DashboardSnapshot(threads: [])

        try await renderer.synchronize(snapshot, on: [target], forceRemount: true)
        XCTAssertEqual(try store.load()?.prompts.first?.preset?.model, "gpt-future")

        let imported = PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "imported",
                name: "Imported",
                content: "Imported content",
                section: "General",
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: nil,
                usePreset: nil
            )],
            sections: ["General"]
        )
        try store.save(imported)
        try await renderer.synchronize(snapshot, on: [target])

        XCTAssertEqual(try store.load(), imported)
        let expressions = await devTools.expressions()
        XCTAssertTrue(expressions.contains { $0.contains("Imported content") })
    }

    func testPendingPromptLibraryIsPersistedBeforeTheNextNativeDelivery() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let nativeLibrary = PromptLibraryDocument(
            version: 3,
            prompts: [],
            sections: []
        )
        let pendingLibrary = PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "pending",
                name: "Pending",
                content: "Must survive a restart",
                section: nil,
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: nil,
                usePreset: nil
            )],
            sections: []
        )
        let pendingData = try JSONEncoder().encode(pendingLibrary)
        let pendingJSON = try XCTUnwrap(String(data: pendingData, encoding: .utf8))
        let devTools = PromptLibraryRendererDevTools(
            target: target,
            exportedLibrary: #"{"version":3,"prompts":[],"sections":[]}"#,
            pendingLibrary: pendingJSON
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-renderer-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        try store.save(nativeLibrary)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            promptLibraryStore: store
        )

        try await renderer.synchronize(
            DashboardSnapshot(threads: []), on: [target], forceRemount: true
        )

        XCTAssertEqual(try store.load(), pendingLibrary)
        let expressions = await devTools.expressions()
        XCTAssertTrue(expressions.contains { $0.contains("acknowledgePendingPromptLibrary") })
    }

    func testNativePromptLibraryImportOverridesPendingRendererEdits() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let imported = PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "imported",
                name: "Imported",
                content: "Imported content",
                section: nil,
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: nil,
                usePreset: nil
            )],
            sections: []
        )
        let pending = PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "pending",
                name: "Pending",
                content: "Pending renderer content",
                section: nil,
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: nil,
                usePreset: nil
            )],
            sections: []
        )
        let importedData = try JSONEncoder().encode(imported)
        let importedJSON = try XCTUnwrap(String(data: importedData, encoding: .utf8))
        let pendingData = try JSONEncoder().encode(pending)
        let pendingJSON = try XCTUnwrap(String(data: pendingData, encoding: .utf8))
        let devTools = PromptLibraryRendererDevTools(
            target: target,
            exportedLibrary: importedJSON
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-renderer-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        try store.save(imported)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            promptLibraryStore: store
        )
        let snapshot = DashboardSnapshot(threads: [])
        try await renderer.synchronize(snapshot, on: [target], forceRemount: true)

        await devTools.setPendingLibrary(pendingJSON)
        renderer.preferNativePromptLibraryOnNextSynchronization()
        try await renderer.synchronize(snapshot, on: [target])

        XCTAssertEqual(try store.load(), imported)
        let expressions = await devTools.expressions()
        XCTAssertTrue(expressions.contains { $0.contains("discardPendingPromptLibrary") })
        XCTAssertTrue(expressions.contains { $0.contains("Imported content") })
    }

}
