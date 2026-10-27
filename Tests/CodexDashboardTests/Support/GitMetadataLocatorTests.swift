import Foundation
import XCTest

@testable import CodexDashboard

final class GitMetadataLocatorTests: XCTestCase {
    func testNestedAndSymlinkPathsShareTheNearestMarker() throws {
        try withDirectory { root in
            let repository = root.appendingPathComponent("repository")
            let nested = repository.appendingPathComponent("nested/deeper")
            let marker = repository.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
            for path in [repository, nested, alias] {
                XCTAssertEqual(GitMetadataLocator.markerURL(for: path)?.path, marker.path)
                XCTAssertEqual(GitMetadataLocator.metadataURL(for: path)?.path, marker.path)
                XCTAssertEqual(FileSystemPath.gitRepositoryRoot(path.path), repository.path)
            }
        }
    }

    func testPointerValidationIsSeparateFromMarkerDiscovery() throws {
        try withDirectory { root in
            let marker = root.appendingPathComponent(".git")
            let metadata = root.appendingPathComponent("metadata")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            try Data("gitdir: metadata\n".utf8).write(to: marker)
            XCTAssertEqual(GitMetadataLocator.metadataURL(for: root)?.path, metadata.path)
            for contents in ["not a Git pointer", "gitdir: missing\n"] {
                try Data(contents.utf8).write(to: marker)
                XCTAssertEqual(GitMetadataLocator.markerURL(for: root), marker)
                XCTAssertNil(GitMetadataLocator.metadataURL(for: root))
            }
            try FileManager.default.removeItem(at: marker)
            try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: "missing")
            XCTAssertEqual(GitMetadataLocator.markerURL(for: root), marker)
            XCTAssertNil(GitMetadataLocator.metadataURL(for: root))
        }
    }

    func testDamagedNestedMarkerDoesNotFallBackToParentMetadata() throws {
        try withDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let marker = nested.appendingPathComponent(".git")
            try Data("invalid".utf8).write(to: marker)
            XCTAssertEqual(GitMetadataLocator.markerURL(for: nested), marker)
            XCTAssertNil(GitMetadataLocator.metadataURL(for: nested))
        }
    }

    func testRootWithoutGitMetadataEndsSearch() throws {
        guard !FileManager.default.fileExists(atPath: "/.git") else {
            throw XCTSkip("Filesystem root is a Git repository on this machine.")
        }
        XCTAssertNil(GitMetadataLocator.metadataURL(for: URL(fileURLWithPath: "/", isDirectory: true)))
        XCTAssertNil(GitMetadataLocator.markerURL(for: URL(fileURLWithPath: "/", isDirectory: true)))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.resolvingSymlinksInPath())
    }
}
