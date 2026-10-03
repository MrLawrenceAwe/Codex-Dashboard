import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopDocumentMigrationTests: ReviewLoopTestCase {
    func testVersionSevenUnconfirmedStopsKeepTheirCheckoutReservation() throws {
        for (message, expectedPhase) in [
            ("Stopped loop. Stopping its running chat.", ReviewLoopPhase.stopping),
            ("Stopped loop, but could not stop its chat. Open its chat to stop it: offline", .stopping),
            ("Stopped loop and its running chat.", .stopped),
        ] {
            var loop = ReviewLoop(id: UUID(), startActionID: "stop", project: project,
                                  promptContext: .general, maxRounds: 2)
            loop.phase = .stopped
            loop.checkoutRoot = project.path
            loop.message = message
            loop.rounds = [ReviewRound(number: 1, baseCommit: "base", threadID: "thread")]
            let data = try JSONEncoder().encode(ReviewLoopsDocument(version: 7, loops: [loop]))
            let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
            XCTAssertEqual(migrated.phase, expectedPhase)
            XCTAssertEqual(migrated.checkoutRoot, project.path)
            XCTAssertEqual(migrated.rounds, loop.rounds)
            XCTAssertEqual(migrated.message, message)
        }
    }

    func testVersionSixPreservesExtensionReloadPreference() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "migration", project: project,
                              promptContext: .general, maxRounds: 5,
                              liveTesting: true, reloadExtensionBeforeTesting: true)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved["isExtension"] = saved.removeValue(forKey: "reloadExtensionBeforeTesting")
        let data = try JSONSerialization.data(withJSONObject: ["version": 6, "loops": [saved]])
        let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
        XCTAssertTrue(migrated.reloadExtensionBeforeTesting)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        XCTAssertNil(current["isExtension"])
        XCTAssertEqual(current["reloadExtensionBeforeTesting"] as? Bool, true)
    }

    func testVersionOneSavedLoopsMigrateWithPushingDisabled() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "saved", project: project,
                              promptContext: .general, maxRounds: 1)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "pushToRemote")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "loops": [saved]])
        let restored = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
        XCTAssertEqual(restored.id, loop.id)
        XCTAssertFalse(restored.pushToRemote)
    }

    func testVersionFourLoopsMigrateWithoutExtensionReload() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "old", project: project,
                              promptContext: .personal, maxRounds: 3, focus: .bugsAndPerformance,
                              liveTesting: true)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "reloadExtensionBeforeTesting")
        let data = try JSONSerialization.data(withJSONObject: ["version": 4, "loops": [saved]])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
    }

    func testVersionThreeLoopsMigrateWithLiveTestingOff() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "old", project: project,
                              promptContext: .personal, maxRounds: 3, focus: .bugsAndPerformance)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "liveTesting")
        let data = try JSONSerialization.data(withJSONObject: ["version": 3, "loops": [saved]])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
    }

    func testVersionTwoNamingFocusMigratesToOrganisationAndNaming() throws {
        let (coordinator, _, _) = try make()
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try XCTUnwrap(coordinator.loops.last))) as? [String: Any])
        saved["focus"] = "naming"
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "loops": [saved]])
        let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
        XCTAssertEqual(migrated.focus, .organisationAndNaming)
        XCTAssertEqual(migrated.id, coordinator.loops.last?.id)
        XCTAssertEqual(migrated.project, coordinator.loops.last?.project)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(migrated)) as? [String: Any])
        XCTAssertEqual(current["focus"] as? String, "organisationAndNaming")
    }

    func testOlderRoundResultsMigrateAddressedCountsWithoutChangingReviewFindings() throws {
        let (coordinator, _, _) = try make()
        var loop = try XCTUnwrap(coordinator.loops.last)
        var round = ReviewRound(number: 1, baseCommit: "base")
        round.review = ReviewReport(outcome: .reviewed, findings: [
            ReviewFinding(priority: .p2, title: "Issue", body: "Details")
        ], summary: "One finding")
        round.result = ReviewRoundResult(outcome: .fixed, addressedFindingCount: 1,
                                         commit: "fixed", summary: "Done")
        loop.rounds = [round]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        var savedRounds = try XCTUnwrap(saved["rounds"] as? [[String: Any]])
        var savedResult = try XCTUnwrap(savedRounds[0]["result"] as? [String: Any])
        savedResult["findings"] = savedResult.removeValue(forKey: "addressedFindingCount")
        savedRounds[0]["result"] = savedResult
        saved["rounds"] = savedRounds
        let formats: [Any] = [saved, [saved]] + (1..<ReviewLoopsDocument.currentVersion).map {
            ["version": $0, "loops": [saved]] as [String: Any]
        }
        for format in formats {
            let data = try JSONSerialization.data(withJSONObject: format)
            let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
            XCTAssertEqual(migrated, loop)
            let currentRound = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(migrated.rounds[0])) as? [String: Any])
            let currentResult = try XCTUnwrap(currentRound["result"] as? [String: Any])
            XCTAssertEqual(currentResult["addressedFindingCount"] as? Int, 1)
            XCTAssertNil(currentResult["findings"])
        }
    }
}
