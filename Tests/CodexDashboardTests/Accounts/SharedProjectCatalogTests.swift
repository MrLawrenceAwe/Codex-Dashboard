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
    func testRenamesPropagateBothWaysAndRemoteAcknowledgementDoesNotEcho() throws {
        var catalog = setup()
        let id = try XCTUnwrap(catalog.replicas["main"]?.links["a"])
        catalog.observe(replicaID: "other", snapshot: [project("b", "Renamed from other")])
        XCTAssertEqual(catalog.projects[id]?.name, "Renamed from other")
        catalog.acknowledge(replicaID: "main", snapshot: [project("a", "Renamed from other")])
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
        catalog.acknowledge(replicaID: "main", snapshot: [])
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
        catalog.acknowledgePinned(replicaID: "other")
        catalog.observePinned(replicaID: "other", localIDs: [])
        XCTAssertEqual(catalog.pinned, [])
        catalog.acknowledgePinned(replicaID: "main")
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
            "app-server-project-id-by-legacy-project-id-by-host": ["local": ["legacy-a": "a", "legacy-b": "b"]]
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
