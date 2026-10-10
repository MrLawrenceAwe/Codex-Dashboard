import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopFileStoreTests: ReviewLoopTestCase {
    func testFileStoreRoundTripsAndDoesNotOverwriteCorruptData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("loop.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReviewLoopFileStore(url: url)
        let (coordinator, _, _) = try make()
        try store.save(coordinator.loops)
        XCTAssertEqual(try store.load(), coordinator.loops)
        let currentDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(currentDocument["version"] as? Int, ReviewLoopsDocument.currentVersion)
        XCTAssertNotNil(currentDocument["loops"] as? [[String: Any]])
        var olderLoop = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(coordinator.loops.last))) as? [String: Any])
        olderLoop.removeValue(forKey: "speed")
        olderLoop.removeValue(forKey: "reviewType")
        olderLoop.removeValue(forKey: "promptContext")
        olderLoop["instructions"] = "(this is a project for personal use)"
        try JSONSerialization.data(withJSONObject: olderLoop).write(to: url)
        XCTAssertEqual(try store.load().first?.speed, .standard)
        XCTAssertEqual(try store.load().first?.reviewType, .bugs)
        XCTAssertEqual(try store.load().first?.promptContext, .personal)
        olderLoop["instructions"] = "(saved custom context)"
        try JSONSerialization.data(withJSONObject: olderLoop).write(to: url)
        XCTAssertEqual(try store.load().first?.promptContext, .savedContext("(saved custom context)"))
        try JSONSerialization.data(withJSONObject: [olderLoop]).write(to: url)
        XCTAssertEqual(try store.load().first?.promptContext, .savedContext("(saved custom context)"))
        var futureDocument = currentDocument
        futureDocument["version"] = ReviewLoopsDocument.currentVersion + 1
        try JSONSerialization.data(withJSONObject: futureDocument).write(to: url)
        XCTAssertThrowsError(try store.load())
        try Data("broken".utf8).write(to: url)
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertNotNil(recovered.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}
