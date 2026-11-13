import XCTest

@testable import CodexDashboard

final class ProjectEditedFileReaderTests: XCTestCase {
    func testOnlyCompletedChangesInsideCheckoutBecomeTabs() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = FileSystemPath.canonicalURL(temp.path)
        let rollout = root.appendingPathComponent("history.jsonl")
        let records = [
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"one.swift":{"type":"add"},"deleted.swift":{"type":"add"}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"failed","changes":{"failed.swift":{"type":"add"}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"deleted.swift":{"type":"delete"},"one.swift":{"type":"update","move_path":"renamed.swift"},"../outside.swift":{"type":"add"}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"latest.swift":{"type":"add"}}}}}"#,
        ]
        try records.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProjectEditedFileReader.paths(in: rollout, root: root), ["latest.swift", "renamed.swift"])
    }
}
