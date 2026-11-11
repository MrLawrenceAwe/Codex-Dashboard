import XCTest

@testable import CodexDashboard

final class GitExecutableTests: XCTestCase {
    func testStandaloneGitTakesPrecedenceOverAppleLauncher() {
        let installed = Set(["/usr/bin/git", "/custom/bin/git", "/opt/homebrew/bin/git"])
        XCTAssertEqual(GitExecutable.resolve(searchPath: "/usr/bin:/custom/bin", isExecutable: installed.contains).path,
                       "/custom/bin/git")
    }

    func testGUILaunchFindsHomebrewOutsidePath() {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            XCTAssertEqual(GitExecutable.resolve(searchPath: "/usr/bin:/bin", isExecutable: { $0 == path }).path, path)
        }
    }

    func testRelativeAndEmptyPathEntriesCannotSelectRepositoryExecutable() {
        var checked: [String] = []
        let result = GitExecutable.resolve(searchPath: ":.:tools:/usr/bin:", isExecutable: {
            checked.append($0)
            return false
        })
        XCTAssertEqual(result.path, "/usr/bin/git")
        XCTAssertEqual(checked, ["/opt/homebrew/bin/git", "/usr/local/bin/git"])
    }

    func testAppleGitRemainsAvailableWithoutStandaloneInstallation() {
        XCTAssertEqual(GitExecutable.resolve(searchPath: nil, isExecutable: { _ in false }).path, "/usr/bin/git")
    }
}
