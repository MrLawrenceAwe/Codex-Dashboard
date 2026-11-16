import XCTest
@testable import CodexDashboard

final class SharedChatProjectAliasesTests: XCTestCase {
    func testLegacyRegistrationsKeepDistinctOriginalProjectsThroughHandoff() throws {
        let result = try SharedChatProjectAliases.aliases(
            for: ["legacy-a", "legacy-b", "original-c"], actualIDs: ["original-a", "original-b", "original-c"],
            oldAliases: ["legacy-a": "replica-a", "legacy-b": "replica-b"],
            windowLinks: ["replica-a": "shared-a", "replica-b": "shared-b"],
            mainByShared: ["shared-a": "original-a", "shared-b": "original-b"],
            mainAliases: [:], previous: ["legacy-a": "removed-duplicate"], main: false
        )
        XCTAssertEqual(result, ["legacy-a": "original-a", "legacy-b": "original-b", "original-c": "original-c"])
    }

    func testActivationRejectsUnknownRegistrationInsteadOfImportingItAgain() {
        XCTAssertThrowsError(try SharedChatProjectAliases.aliases(
            for: ["unmatched"], actualIDs: ["original"], oldAliases: [:], windowLinks: [:],
            mainByShared: [:], mainAliases: [:], previous: ["unmatched": "removed"], main: false
        ))
    }

    func testMainUsesItsOriginalHostMappingBeforeExistingSharedHostMapping() throws {
        let result = try SharedChatProjectAliases.aliases(
            for: ["legacy"], actualIDs: ["original", "duplicate"], oldAliases: [:], windowLinks: [:],
            mainByShared: [:], mainAliases: ["legacy": "original"], previous: ["legacy": "duplicate"], main: true
        )
        XCTAssertEqual(result, ["legacy": "original"])
    }
}
