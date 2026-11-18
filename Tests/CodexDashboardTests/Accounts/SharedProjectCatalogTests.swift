import XCTest
@testable import CodexDashboard

final class SharedProjectCatalogTests: XCTestCase {
    private func project(_ id: String, _ name: String, path: String = "/tmp/shared") -> CodexProject {
        .init(id: id, name: name, roots: [.init(path: path)])
    }
    private func setup() -> SharedProjectCatalog {
        var catalog = SharedProjectCatalog()
        catalog.observe(replicaID: "main", snapshot: [project("a", "Original")])
        catalog.observe(replicaID: "other", snapshot: [project("b", "Original")])
        return catalog
    }
    func testPresentationIgnoresAliasFromAnotherBackend() {
        let presentation = ProjectListPresentation.read(state: [
            "local-projects": ["server": [:], "foreign-import": [:]],
            "project-order": ["foreign-import", "server"],
            "app-server-project-id-by-legacy-project-id-by-host": ["shared": ["foreign-import": "server"]]
        ], projects: [project("server", "Original")], hostID: "local")
        XCTAssertEqual(presentation.legacyByServer["server"], "server")
        XCTAssertEqual(presentation.unmapped, ["foreign-import"])
        XCTAssertTrue(presentation.duplicateAliases.isEmpty)
    }

    func testPresentationCollapsesTwoSidebarAliasesForTheSameRegistration() {
        let presentation = ProjectListPresentation.read(state: [
            "local-projects": ["server": [:], "old-import": [:]],
            "project-order": ["old-import", "server"],
            "app-server-project-id-by-legacy-project-id-by-host": ["local": ["old-import": "server"]]
        ], projects: [project("server", "Original")], hostID: "local")
        XCTAssertEqual(presentation.duplicateAliases, ["server"])
        XCTAssertEqual(presentation.order, ["server"])
        XCTAssertEqual(presentation.merging(localIDs: ["server"], into: presentation.rawOrder), ["old-import"])
    }

    func testPresentationReusesNativeAliasEvenIfOnlyServerIDIsCached() {
        let presentation = ProjectListPresentation.read(state: [
            "local-projects": ["server": [:]],
            "project-order": ["server"],
            "pinned-project-ids": ["server"],
            "app-server-project-id-by-legacy-project-id-by-host": [
                "local": ["own-import": "server"], "shared": ["foreign-import": "server"]
            ]
        ], projects: [project("server", "Original")], hostID: "local")
        XCTAssertEqual(presentation.legacyByServer["server"], "own-import")
        XCTAssertEqual(presentation.duplicateAliases, ["server"])
        XCTAssertEqual(presentation.pinned, ["server"])
        XCTAssertEqual(presentation.merging(localIDs: presentation.pinned, into: presentation.rawPinned), ["own-import"])
    }

    func testSharedBackendUsesOneIdentityForNewUnmarkedProject() throws {
        var catalog = setup()
        let snapshot = [project("a", "Original"), project("new", "New")]
        catalog.observe(replicaID: "main", snapshot: snapshot)
        catalog.alignSharedBackend(replicaID: "shared:other", snapshot: snapshot)
        catalog.observe(replicaID: "shared:other", snapshot: snapshot)
        XCTAssertEqual(catalog.projects.count, 2)
        XCTAssertEqual(catalog.replicas["main"]?.links["new"], catalog.replicas["shared:other"]?.links["new"])
        XCTAssertTrue(catalog.deleted.isEmpty)
        XCTAssertNotNil(catalog.replicas["other"]?.observed["b"], "The independent backend is retained")
        catalog.observe(replicaID: "other", snapshot: [project("b", "Original")])
        XCTAssertEqual(catalog.projects.count, 2)
        XCTAssertTrue(catalog.deleted.isEmpty)
    }

    func testExistingImportedProjectsAdoptOneIdentityWithoutCollapsingDuplicates() throws {
        var catalog = SharedProjectCatalog()
        catalog.observe(replicaID: "main", snapshot: [project("a", "First"), project("b", "Second")])
        catalog.observe(replicaID: "other", snapshot: [project("x", "First")])
        XCTAssertEqual(catalog.projects.count, 2)
        XCTAssertEqual(catalog.replicas["main"]?.links["a"], catalog.replicas["other"]?.links["x"])
    }

    func testFirstSyncKeepsDifferentRegistrationsForTheSameFolder() throws {
        var catalog = SharedProjectCatalog()
        let main = project("a", "Client delivery")
        let renamed = project("b", "Personal experiments")
        var annotated = project("c", "Client delivery")
        annotated.metadata["color"] = "blue"
        catalog.observe(replicaID: "main", snapshot: [main])
        catalog.observe(replicaID: "other", snapshot: [renamed, annotated])
        XCTAssertEqual(catalog.order.compactMap { catalog.projects[$0] },
                       [main, renamed, annotated].map(SharedProjectCatalog.Value.init))
        XCTAssertNotEqual(catalog.replicas["main"]?.links["a"], catalog.replicas["other"]?.links["b"])
        XCTAssertNotEqual(catalog.replicas["main"]?.links["a"], catalog.replicas["other"]?.links["c"])
    }

    func testPresentationAcknowledgementPreservesConcurrentProjectChanges() throws {
        var catalog = setup()
        let id = try XCTUnwrap(catalog.replicas["main"]?.links["a"])
        let applied = project("a", "Merged name")
        catalog.observe(replicaID: "other", snapshot: [project("b", applied.name)])
        catalog.acknowledgeProject(replicaID: "main", localID: "a", sharedID: id, value: .init(applied))

        // The user can change the catalog while the order and pins are saved.
        catalog.acknowledgePresentation(replicaID: "main", order: ["a"], pinned: [])
        catalog.observe(replicaID: "main", snapshot: [project("a", "Concurrent rename")])
        XCTAssertEqual(catalog.projects[id]?.name, "Concurrent rename")
        catalog.acknowledgePresentation(replicaID: "main", order: ["a"], pinned: [])
        catalog.observe(replicaID: "main", snapshot: [])
        XCTAssertNil(catalog.projects[id])
        XCTAssertTrue(catalog.deleted.contains(id))
    }

    func testRenamesPropagateBothWaysAndRemoteAcknowledgementDoesNotEcho() throws {
        var catalog = setup()
        let id = try XCTUnwrap(catalog.replicas["main"]?.links["a"])
        catalog.observe(replicaID: "other", snapshot: [project("b", "Renamed from other")])
        XCTAssertEqual(catalog.projects[id]?.name, "Renamed from other")
        catalog.acknowledgeProject(replicaID: "main", localID: "a", sharedID: id,
                                   value: .init(project("a", "Renamed from other")))
        catalog.observe(replicaID: "main", snapshot: [project("a", "Renamed from main")])
        catalog.observe(replicaID: "other", snapshot: [project("b", "Renamed from other")])
        XCTAssertEqual(catalog.projects[id]?.name, "Renamed from main")
    }
    func testRemovalWinsOverStaleOfflineReplicaAndNewFolderCanBeAddedAgain() throws {
        var catalog = setup()
        let id = try XCTUnwrap(catalog.replicas["main"]?.links["a"])
        catalog.observe(replicaID: "other", snapshot: [])
        catalog.observe(replicaID: "main", snapshot: [project("a", "Original")])
        XCTAssertNil(catalog.projects[id]); XCTAssertTrue(catalog.deleted.contains(id))
        catalog.retire(replicaID: "main", localID: "a")
        catalog.observe(replicaID: "main", snapshot: [project("new-id", "Added again")])
        XCTAssertEqual(catalog.projects.count, 1)
        XCTAssertNotEqual(catalog.replicas["main"]?.links["new-id"], id)
    }
    func testIndependentFieldEditsMergeRatherThanReplacingOneAnother() throws {
        var catalog = setup()
        catalog.observe(replicaID: "main", snapshot: [project("a", "Renamed")])
        var other = project("b", "Original"); other.metadata["color"] = "blue"
        catalog.observe(replicaID: "other", snapshot: [other])
        let id = try XCTUnwrap(catalog.replicas["main"]?.links["a"])
        XCTAssertEqual(catalog.projects[id]?.name, "Renamed")
        XCTAssertEqual(catalog.projects[id]?.metadata["color"], "blue")
    }
    func testNewProjectsAndOrderingFromEitherReplicaAreShared() throws {
        var catalog = setup()
        catalog.observe(replicaID: "other", snapshot: [project("new", "New", path: "/tmp/another"), project("b", "Original")])
        XCTAssertEqual(catalog.order.compactMap { catalog.projects[$0]?.name }, ["New", "Original"])
        catalog.observe(replicaID: "other", snapshot: [project("b", "Original"), project("new", "New", path: "/tmp/another")])
        XCTAssertEqual(catalog.order.compactMap { catalog.projects[$0]?.name }, ["Original", "New"])
    }
    func testPinsMergeInBothDirectionsWithoutUnpinningFreshWindows() throws {
        var catalog = setup()
        let id = try XCTUnwrap(catalog.replicas["main"]?.links["a"])
        catalog.observePinned(replicaID: "main", localIDs: ["a"])
        catalog.observePinned(replicaID: "other", localIDs: [])
        XCTAssertEqual(catalog.pinned, [id])
        catalog.acknowledgePresentation(replicaID: "other", order: ["b"], pinned: ["b"])
        catalog.observePinned(replicaID: "other", localIDs: [])
        XCTAssertEqual(catalog.pinned, [])
        catalog.acknowledgePresentation(replicaID: "main", order: ["a"], pinned: [])
        catalog.observePinned(replicaID: "main", localIDs: ["a"])
        XCTAssertEqual(catalog.pinned, [id])
    }

    func testSidebarPresentationTranslatesNativeIDsAndPreservesRemoteEntries() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = try JSONSerialization.data(withJSONObject: [
            "project-order": ["legacy-a", "remote-project", "legacy-b"],
            "pinned-project-ids": ["legacy-a", "remote-project"],
            "app-server-project-id-by-legacy-project-id-by-host": [
                ProjectListPresentation.hostID(home: home): ["legacy-a": "a", "legacy-b": "b"]
            ]
        ])
        try data.write(to: home.appendingPathComponent(".codex-global-state.json"))
        let value = try ProjectListPresentation.read(home: home, projects: [project("a", "A"), project("b", "B")])
        XCTAssertEqual(value.order, ["a", "b"])
        XCTAssertEqual(value.pinned, ["a"])
        XCTAssertEqual(value.merging(localIDs: ["b", "a"], into: value.rawOrder), ["legacy-b", "remote-project", "legacy-a"])
        XCTAssertEqual(value.merging(localIDs: [], into: value.rawPinned), ["remote-project"])
    }

    func testInterruptedCreateUsesMarkerInsteadOfDuplicatingRegistration() throws {
        var catalog = setup()
        let id = try XCTUnwrap(catalog.order.first)
        var restored = project("new-local-id", "Original")
        restored.metadata[SharedProjectCatalog.marker] = id
        catalog.observe(replicaID: "fresh", snapshot: [restored])
        XCTAssertEqual(catalog.projects.count, 1)
        XCTAssertEqual(catalog.replicas["fresh"]?.links["new-local-id"], id)
        let data = try JSONEncoder().encode(catalog)
        XCTAssertEqual(try JSONDecoder().decode(SharedProjectCatalog.self, from: data), catalog)
    }
}
