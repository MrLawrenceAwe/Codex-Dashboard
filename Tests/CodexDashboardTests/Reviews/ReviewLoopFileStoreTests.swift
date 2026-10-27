import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopFileStoreTests: ReviewLoopTestCase {
    func testFileStoreRoundTripsCurrentDocument() throws {
        try withTemporaryStore { store, url in
            let (coordinator, _, _) = try make()
            try store.save(coordinator.loops)
            XCTAssertEqual(try store.load(), coordinator.loops)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(document["version"] as? Int, ReviewLoopsDocument.currentVersion)
            XCTAssertNotNil(document["loops"] as? [[String: Any]])
        }
    }

    func testFileStoreRejectsFutureVersionWithoutOverwritingIt() throws {
        try withTemporaryStore { store, url in
            let data = try JSONSerialization.data(withJSONObject: [
                "version": ReviewLoopsDocument.currentVersion + 1, "loops": []
            ])
            try data.write(to: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testCoordinatorPreservesCorruptDocumentOnInitializationFailure() throws {
        try withTemporaryStore { store, url in
            try Data("broken".utf8).write(to: url)
            let coordinator = ReviewLoopCoordinator(store: store)
            XCTAssertNotNil(coordinator.error)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
        }
    }

    func testInitializationSaveFailureIsReportedAsStorageInitializationFailure() {
        let store = ReviewTestStore()
        store.failSave = true
        let coordinator = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(coordinator.error, "Review loop storage could not be initialized: disk full")
    }

    private func withTemporaryStore(_ operation: (ReviewLoopFileStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("loop.json")
        try operation(ReviewLoopFileStore(url: url), url)
    }
}
