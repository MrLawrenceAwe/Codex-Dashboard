import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension DashboardRendererTests {
    func testPromptExportIncludesPendingEditsBeforeSynchronizationDeadline() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: "app://-/index.html",
                                    webSocketURL: "ws://127.0.0.1/main")
        let initial = #"{"version":4,"prompts":[],"sections":[]}"#
        let pending = #"{"version":4,"prompts":[{"id":"new","name":"New","content":"Latest edit","scope":{"type":"global"}}],"sections":[]}"#
        let devTools = PromptLibraryRendererDevTools(target: target, exportedLibrary: initial)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            promptLibraryStore: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let snapshot = DashboardSnapshot(threads: [])
        try await renderer.synchronize(snapshot, on: [target], forceRemount: true)
        await devTools.setPendingLibrary(pending)
        // A normal poll inside the ten-second interval leaves this edit queued.
        try await renderer.synchronize(snapshot, on: [target])
        let destination = directory.appendingPathComponent("export.json")
        let runtime = StubDashboardRuntime()
        runtime.onPromptLibraryFlush = { try await renderer.flushPromptLibrary() }
        let coordinator = makeAppCoordinator(promptLibraryStore: store, runtimeFactory: { _ in runtime })
        await coordinator.exportPromptLibrary(to: destination)
        let exported = try JSONDecoder().decode(PromptLibraryDocument.self, from: Data(contentsOf: destination))
        XCTAssertEqual(exported.prompts.first?.content, "Latest edit")
        XCTAssertEqual(coordinator.promptLibraryStatusMessage, "Exported prompt library.")
    }

    func testPromptExportBeforeFirstSynchronizationIncludesPendingLibrary() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: "app://-/index.html",
                                    webSocketURL: "ws://127.0.0.1/main")
        let library = #"{"version":4,"prompts":[{"id":"new","name":"New","content":"First prompt","scope":{"type":"global"}}],"sections":[]}"#
        let devTools = PromptLibraryRendererDevTools(target: target, exportedLibrary: library, pendingLibrary: library)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        let renderer = try DashboardRenderer(devTools: devTools, promptLibraryStore: store)
        let runtime = StubDashboardRuntime()
        runtime.onPromptLibraryFlush = { try await renderer.flushPromptLibrary() }
        let coordinator = makeAppCoordinator(promptLibraryStore: store, runtimeFactory: { _ in runtime })
        let destination = directory.appendingPathComponent("export.json")
        await coordinator.exportPromptLibrary(to: destination)
        let exported = try JSONDecoder().decode(PromptLibraryDocument.self, from: Data(contentsOf: destination))
        XCTAssertEqual(exported.prompts.first?.content, "First prompt")
    }

    func testPromptExportPreservesDestinationWhenRendererReadFails() async throws {
        for response in [nil, "invalid JSON", #"{"version":99,"prompts":[],"sections":[]}"#] as [String?] {
            let devTools = UnavailablePromptExportDevTools(response: response)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
            try store.save(.empty)
            let renderer = try DashboardRenderer(devTools: devTools, promptLibraryStore: store)
            let runtime = StubDashboardRuntime()
            runtime.onPromptLibraryFlush = { try await renderer.flushPromptLibrary() }
            let coordinator = makeAppCoordinator(promptLibraryStore: store, runtimeFactory: { _ in runtime })
            let destination = directory.appendingPathComponent("export.json")
            let original = Data("Existing backup".utf8)
            try original.write(to: destination)
            await coordinator.exportPromptLibrary(to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertNotEqual(coordinator.promptLibraryStatusMessage, "Exported prompt library.")
            XCTAssertFalse(coordinator.isPerformingAction)
        }
    }

    func testPromptLibraryMigratesToNativeStoreAndExternalImportWins() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let rendererLibrary = #"{"version":4,"prompts":[{"id":"old","name":"Old","content":"Old content","scope":{"type":"global"},"preset":{"model":"gpt-future"}}],"sections":[]}"#
        let devTools = PromptLibraryRendererDevTools(target: target, exportedLibrary: rendererLibrary)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            promptLibraryStore: store,
            promptLibrarySynchronizationInterval: 10,
            now: { currentDate }
        )
        let snapshot = DashboardSnapshot(threads: [])

        try await renderer.synchronize(snapshot, on: [target], forceRemount: true)
        XCTAssertEqual(try store.load()?.prompts.first?.preset?.model, "gpt-future")
        let initialPromptLibraryReadCount = await devTools.promptLibraryReadCount()

        try await renderer.synchronize(snapshot, on: [target])
        let unchangedPromptLibraryReadCount = await devTools.promptLibraryReadCount()
        XCTAssertEqual(unchangedPromptLibraryReadCount, initialPromptLibraryReadCount)

        let imported = PromptLibraryDocument(
            version: PromptLibrarySchema.currentVersion,
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
        currentDate.addTimeInterval(11)
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
            version: PromptLibrarySchema.currentVersion,
            prompts: [],
            sections: []
        )
        let pendingLibrary = PromptLibraryDocument(
            version: PromptLibrarySchema.currentVersion,
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
            exportedLibrary: #"{"version":4,"prompts":[],"sections":[]}"#,
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

    func testPendingPromptLibraryIsAcknowledgedAcrossRendererTargets() async throws {
        let firstTarget = DevToolsTarget(
            id: "first", type: "page", url: "app://-/index.html", webSocketURL: "ws://127.0.0.1/first"
        )
        let secondTarget = DevToolsTarget(
            id: "second", type: "page", url: "app://-/index.html", webSocketURL: "ws://127.0.0.1/second"
        )
        let pendingLibrary = PromptLibraryDocument(
            version: PromptLibrarySchema.currentVersion,
            prompts: [SavedPrompt(
                id: "pending", name: "Pending", content: "Persist me", section: nil,
                scope: SavedPromptScope(type: "global", projectPath: nil), preset: nil, usePreset: nil
            )],
            sections: []
        )
        let pendingJSON = try XCTUnwrap(String(data: JSONEncoder().encode(pendingLibrary), encoding: .utf8))
        let devTools = MultiTargetPromptLibraryRendererDevTools(
            targets: [firstTarget, secondTarget],
            exportedLibrary: #"{"version":4,"prompts":[],"sections":[]}"#,
            pendingLibraryByTargetID: [firstTarget.id: pendingJSON, secondTarget.id: pendingJSON]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-target-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            promptLibraryStore: PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        )

        try await renderer.synchronize(
            DashboardSnapshot(threads: []), on: [firstTarget, secondTarget], forceRemount: true
        )

        let acknowledgementTargetIDs = await devTools.acknowledgementTargetIDs()
        let firstPendingLibrary = await devTools.pendingLibrary(for: firstTarget.id)
        let secondPendingLibrary = await devTools.pendingLibrary(for: secondTarget.id)
        XCTAssertEqual(acknowledgementTargetIDs, [firstTarget.id, secondTarget.id])
        XCTAssertNil(firstPendingLibrary)
        XCTAssertNil(secondPendingLibrary)
    }

    func testNativePromptLibraryImportOverridesPendingRendererEdits() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let imported = PromptLibraryDocument(
            version: PromptLibrarySchema.currentVersion,
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
            version: PromptLibrarySchema.currentVersion,
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
        renderer.useStoredPromptLibraryOnNextSync()
        try await renderer.synchronize(snapshot, on: [target])

        XCTAssertEqual(try store.load(), imported)
        let expressions = await devTools.expressions()
        XCTAssertTrue(expressions.contains { $0.contains("discardPendingPromptLibrary") })
        XCTAssertTrue(expressions.contains { $0.contains("Imported content") })
    }

}

private actor UnavailablePromptExportDevTools: DevToolsServing {
    let response: String?
    init(response: String?) { self.response = response }
    func mainRendererTargets() -> [DevToolsTarget] {
        [DevToolsTarget(id: "main", type: "page", url: "app://-/index.html", webSocketURL: "ws://127.0.0.1/main")]
    }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool { true }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { response }
}
