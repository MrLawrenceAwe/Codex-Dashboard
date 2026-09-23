import Foundation
import XCTest

@testable import CodexDashboard

final class GitMetadataLocatorTests: XCTestCase {
    func testRootWithoutGitMetadataEndsSearch() throws {
        guard !FileManager.default.fileExists(atPath: "/.git") else {
            throw XCTSkip("Filesystem root is a Git repository on this machine.")
        }
        XCTAssertNil(GitMetadataLocator.metadataURL(for: URL(fileURLWithPath: "/", isDirectory: true)))
    }
}
