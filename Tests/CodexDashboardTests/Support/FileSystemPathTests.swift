import XCTest
@testable import CodexDashboard

final class FileSystemPathTests: XCTestCase {
    func testContainmentRespectsPathComponentsAndFilesystemRoot() {
        XCTAssertTrue(FileSystemPath.contains("/project", in: "/project"))
        XCTAssertTrue(FileSystemPath.contains("/project/source/file.swift", in: "/project"))
        XCTAssertFalse(FileSystemPath.contains("/project-other/file.swift", in: "/project"))
        XCTAssertFalse(FileSystemPath.contains("/other/project", in: "/project"))
        XCTAssertTrue(FileSystemPath.contains("/", in: "/"))
        XCTAssertTrue(FileSystemPath.contains("/project/file.swift", in: "/"))
        XCTAssertFalse(FileSystemPath.contains("relative/path", in: "/"))
    }

    func testOverlapIncludesEitherAncestorAndExcludesSiblingPrefixes() {
        XCTAssertTrue(FileSystemPath.overlaps("/project", "/project"))
        XCTAssertTrue(FileSystemPath.overlaps("/project", "/project/source"))
        XCTAssertTrue(FileSystemPath.overlaps("/project/source", "/project"))
        XCTAssertTrue(FileSystemPath.overlaps("/", "/project"))
        XCTAssertTrue(FileSystemPath.overlaps("/project", "/"))
        XCTAssertFalse(FileSystemPath.overlaps("/project", "/project-other"))
    }
}
