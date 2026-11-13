import XCTest
@testable import CodexDashboard

final class ProjectFileScannerTests: XCTestCase {
    func testScanExcludesGeneratedTreesSymlinksAndBinaryContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "func hello() {\r\n}\r\n".write(to: root.appendingPathComponent("hello.swift"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("node_modules/dependency.js"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("image.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        let scan = try ProjectFileScanner.scan(root: root)
        XCTAssertEqual(Set(scan.files.map(\.path)), ["hello.swift", "image.bin"])
        XCTAssertEqual(scan.files.first(where: { $0.path == "hello.swift" })?.lines, 2)
        XCTAssertEqual(scan.files.first(where: { $0.path == "hello.swift" })?.functions.first?.lineCount, 2)
        XCTAssertNil(scan.files.first(where: { $0.path == "image.bin" })?.lines)
    }

    func testLargeFilesAreListedWithoutReadingAndEmptyFilesCountZero() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: ProjectFileScanner.maximumFileBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        try Data().write(to: root.appendingPathComponent("empty.txt"))
        let scan = try ProjectFileScanner.scan(root: root)
        XCTAssertEqual(scan.files.first(where: { $0.path == "empty.txt" })?.lines, 0)
        XCTAssertNil(scan.files.first(where: { $0.path == "large.txt" })?.lines)
        XCTAssertThrowsError(try ProjectFileScanner.readText(at: root.appendingPathComponent("large.txt")))
    }
}
