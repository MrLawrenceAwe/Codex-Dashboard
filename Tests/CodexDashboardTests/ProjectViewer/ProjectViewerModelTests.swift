import XCTest
@testable import CodexDashboard

@MainActor
final class ProjectViewerModelTests: XCTestCase {
    private func waitForScan(_ model: ProjectViewerModel) async throws {
        for _ in 0..<200 {
            if !model.isScanning { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Project scan timed out")
    }

    func testGrowthRemovalFunctionNavigationAndBaselineReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.swift")
        try "func hello() {\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let model = ProjectViewerModel()
        defer { model.stop() }
        model.open(root)
        try await waitForScan(model)
        XCTAssertEqual(model.totalDelta, 0)
        XCTAssertEqual(model.selectedPath, "source.swift")
        try "func hello() {\n print(1)\n}\nfunc added() {}\n".write(to: file, atomically: true, encoding: .utf8)
        model.refresh()
        try await waitForScan(model)
        XCTAssertEqual(model.lineDelta("source.swift"), 2)
        XCTAssertEqual(model.functionRows.first?.delta, 1)
        XCTAssertTrue(model.functionRows.contains { $0.added && $0.function.name == "added" })
        model.changedOnly = true
        XCTAssertEqual(model.visiblePaths, ["source.swift"])
        try FileManager.default.removeItem(at: file)
        model.refresh()
        try await waitForScan(model)
        XCTAssertEqual(model.lineDelta("source.swift"), -2)
        XCTAssertTrue(model.functionRows.allSatisfy(\.removed))
        XCTAssertNotNil(model.previewMessage)
        model.resetBaseline()
        XCTAssertTrue(model.visiblePaths.isEmpty)
        XCTAssertEqual(model.totalDelta, 0)
    }

    func testChatTabsOpenInHistoryOrderAndStayClosedAfterRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["a.txt", "b.txt", "unrelated.txt"] {
            try "text".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let model = ProjectViewerModel()
        defer { model.stop() }
        model.open(root, selectInitialFile: false)
        model.openEditedFiles { ["b.txt", "a.txt", "b.txt", "gone.txt"] }
        try await waitForScan(model)
        XCTAssertEqual(model.tabs, ["b.txt", "a.txt"])
        XCTAssertEqual(model.selectedPath, "b.txt")
        model.closeTab("b.txt")
        XCTAssertEqual(model.selectedPath, "a.txt")
        model.closeTab("a.txt")
        model.refresh()
        try await waitForScan(model)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selectedPath)
    }

    func testProjectSwitchDoesNotKeepPreviousFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "one".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        let model = ProjectViewerModel()
        defer { model.stop() }
        model.open(root)
        model.open(second)
        try await waitForScan(model)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.baseline.isEmpty)
        XCTAssertNil(model.selectedPath)
    }

    func testProjectCanBeBrowsedWhileEditedTabsLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["edited.txt", "selected.txt"] {
            try file.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let model = ProjectViewerModel()
        defer { model.stop() }
        var finishHistory: CheckedContinuation<[String], Never>?
        model.open(root, selectInitialFile: false)
        model.openEditedFiles { await withCheckedContinuation { finishHistory = $0 } }
        defer { finishHistory?.resume(returning: []) }

        try await waitForScan(model)
        XCTAssertEqual(model.visiblePaths, ["edited.txt", "selected.txt"])
        XCTAssertNil(model.selectedPath)
        model.selectedPath = "selected.txt"

        let history = try XCTUnwrap(finishHistory)
        finishHistory = nil
        history.resume(returning: ["edited.txt"])
        for _ in 0..<100 where !model.tabs.contains("edited.txt") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.tabs, ["edited.txt", "selected.txt"])
        XCTAssertEqual(model.selectedPath, "selected.txt")
    }
}
