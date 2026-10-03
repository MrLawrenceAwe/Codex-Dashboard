import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopBridgeTests: ReviewLoopTestCase {
    func testUnknownReviewActionKindDoesNotDecode() {
        let payload = Data(#"{"id":"unknown","kind":"retry"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewLoopAction.self, from: payload))
    }

    func testReviewFileLinksStayInsideTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-files-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("File.swift")
        try Data("source".utf8).write(to: file)
        let outside = root.appendingPathComponent("outside.swift")
        try Data("outside".utf8).write(to: outside)
        let alias = project.appendingPathComponent("alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        XCTAssertEqual(ReviewLoopBridge.reviewFileURL("File.swift:12", projectPath: project.path), file)
        XCTAssertEqual(ReviewLoopBridge.reviewFileURL(file.absoluteString, projectPath: project.path), file)
        XCTAssertNil(ReviewLoopBridge.reviewFileURL("../outside.swift", projectPath: project.path))
        XCTAssertNil(ReviewLoopBridge.reviewFileURL(outside.path, projectPath: project.path))
        XCTAssertNil(ReviewLoopBridge.reviewFileURL("alias.swift", projectPath: project.path))
    }
}
