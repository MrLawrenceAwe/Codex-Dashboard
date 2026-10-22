import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopDocumentMigrationTests: ReviewLoopTestCase {
    func testWorkspaceRootMigrationPreservesGitAndFolderReservationsAndHistory() throws {
        for kind in [ReviewWorkspaceKind.git, .folder] {
            var loop = ReviewLoop(id: UUID(), startActionID: "root-migration", project: project,
                                  promptContext: .personal, maxRounds: 3, priorityLimit: .p2)
            loop.workspaceKind = kind
            loop.workspaceRoot = project.path
            loop.phase = .paused
            loop.branch = kind == .git ? "main" : nil
            loop.expectedRevision = "saved-revision"
            loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "saved-thread")]
            var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
            saved["checkoutRoot"] = saved.removeValue(forKey: "workspaceRoot")
            for version in (kind == .git ? 1 : 14)...15 {
                let data = try JSONSerialization.data(withJSONObject: ["version": version, "loops": [saved]])
                let migrated = try ReviewLoopDocumentMigration.decode(data)
                XCTAssertEqual(migrated, [loop])
                let rewritten = try JSONEncoder().encode(ReviewLoopsDocument(
                    version: ReviewLoopsDocument.currentVersion, loops: migrated))
                XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("checkoutRoot"))
                XCTAssertEqual(try ReviewLoopDocumentMigration.decode(rewritten), [loop])
                let store = ReviewTestStore()
                store.loops = migrated
                XCTAssertEqual(ReviewLoopCoordinator(store: store).loops, [loop])
            }
        }
    }

    func testSavedModelSelectionMigratesToCurrentNames() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "saved", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 2)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved["reviewSelection"] = ["model": "chosen", "effort": "high"]
        let selection = try XCTUnwrap(ReviewLoopDocumentMigration.decode(JSONSerialization.data(withJSONObject: saved)).first?.reviewSelection)
        XCTAssertEqual(selection.modelID, "chosen")
        XCTAssertEqual(selection.reasoningEffort, "high")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: String])
        XCTAssertEqual(encoded, ["modelID": "chosen", "reasoningEffort": "high"])
    }

    func testSavedLoopCarriesPreviousSelectionIntoBothTurns() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "saved", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 2)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved["selection"] = ["modelID": "previous-model", "reasoningEffort": "high"]
        let restored = try XCTUnwrap(ReviewLoopDocumentMigration.decode(JSONSerialization.data(withJSONObject: saved)).first)
        XCTAssertEqual(restored.reviewSelection?.modelID, "previous-model")
        XCTAssertEqual(restored.fixSelection?.reasoningEffort, "high")
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil(rewritten["selection"])
        XCTAssertNotNil(rewritten["reviewSelection"])
        XCTAssertNotNil(rewritten["fixSelection"])
    }

    func testLegacyResultCommitsPreserveRevisionsWithoutInventingFixCommits() throws {
        let cases: [(String, String, String?, String?, String?)] = [
            ("fixed", "fix", "head", "fix", "head"),
            ("fixed", "fix", nil, "fix", nil),
            ("clean", "base", nil, nil, "base"),
            ("withdrawn", "base", nil, nil, "base"),
            ("fixed", "", "fingerprint", nil, "fingerprint"),
            ("blocked", "", nil, nil, nil),
        ]
        for (outcome, commit, verified, expectedFix, expectedRevision) in cases {
            let loop = ReviewLoop(id: UUID(), startActionID: "result-migration", project: project,
                                  promptContext: .general, maxRounds: 2)
            var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
            var result: [String: Any] = ["outcome": outcome, "commit": commit,
                                       "addressedFindingCount": outcome == "fixed" ? 1 : 0, "summary": "Saved"]
            result["verifiedRevision"] = verified
            saved["rounds"] = [["number": 1, "baseRevision": "base", "fixRequested": true,
                                 "allowsFollowUpTurns": false, "extensionReloadContinuationPending": false,
                                 "result": result]]
            for version in [1, 8, 13, 14] {
                let data = try JSONSerialization.data(withJSONObject: ["version": version, "loops": [saved]])
                let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first?.rounds.first?.result)
                XCTAssertEqual(migrated.fixCommit, expectedFix)
                XCTAssertEqual(migrated.verifiedRevision, expectedRevision)
                let current = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
                XCTAssertNil(current["commit"])
                XCTAssertEqual(try JSONDecoder().decode(ReviewRoundResult.self, from: JSONEncoder().encode(migrated)), migrated)
            }
        }
    }

    func testVersionThirteenPreservesGitHistoryAndLeavesUnstartedFolderModeUndecided() throws {
        var loop = ReviewLoop(id: UUID(), startActionID: "old", project: project, promptContext: .general, maxRounds: 2)
        loop.workspaceKind = .git
        loop.workspaceRoot = project.path
        loop.branch = "main"
        loop.expectedRevision = "head"
        loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread",
            fixVerification: ReviewFixVerification(sourceFixTurnID: "fix", targetRevision: "head", turnID: "verify"),
            result: ReviewRoundResult(outcome: .fixed, addressedFindingCount: 1, fixCommit: "fix", summary: "Saved", verifiedRevision: "head"))]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "workspaceKind")
        saved["checkoutRoot"] = saved.removeValue(forKey: "workspaceRoot")
        saved["expectedCommit"] = saved.removeValue(forKey: "expectedRevision")
        var rounds = try XCTUnwrap(saved["rounds"] as? [[String: Any]])
        rounds[0]["baseCommit"] = rounds[0].removeValue(forKey: "baseRevision")
        var verification = try XCTUnwrap(rounds[0]["fixVerification"] as? [String: Any])
        verification["targetCommit"] = verification.removeValue(forKey: "targetRevision")
        rounds[0]["fixVerification"] = verification
        var result = try XCTUnwrap(rounds[0]["result"] as? [String: Any])
        result["commit"] = result.removeValue(forKey: "fixCommit")
        result["verifiedCommit"] = result.removeValue(forKey: "verifiedRevision")
        rounds[0]["result"] = result
        saved["rounds"] = rounds
        let data = try JSONSerialization.data(withJSONObject: ["version": 13, "loops": [saved]])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
        saved.removeValue(forKey: "checkoutRoot")
        saved.removeValue(forKey: "expectedCommit")
        saved["rounds"] = []
        let unstarted = try JSONSerialization.data(withJSONObject: ["version": 13, "loops": [saved]])
        XCTAssertNil(try ReviewLoopDocumentMigration.decode(unstarted).first?.workspaceKind)
    }

    func testContinuationStateMigrationPreservesPermissionsAndPendingReloads() throws {
        for permission in [nil, false, true] as [Bool?] {
            for pendingReload in [nil, false, true] as [Bool?] {
                var loop = ReviewLoop(id: UUID(), startActionID: "continuation", project: project,
                                      promptContext: .general, maxRounds: 3, priorityLimit: .p2)
                loop.phase = .awaitingExtensionReload
                loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread",
                                          allowsFollowUpTurns: permission ?? false,
                                          extensionReloadContinuationPending: pendingReload ?? false)]
                var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
                var rounds = try XCTUnwrap(saved["rounds"] as? [[String: Any]])
                rounds[0].removeValue(forKey: "allowsFollowUpTurns")
                rounds[0].removeValue(forKey: "extensionReloadContinuationPending")
                rounds[0]["continuationRequested"] = permission
                rounds[0]["reloadContinuationRequested"] = pendingReload
                saved["rounds"] = rounds
                let formats: [Any] = [saved, [saved]] + (1...12).map {
                    ["version": $0, "loops": [saved]] as [String: Any]
                }
                for format in formats {
                    let data = try JSONSerialization.data(withJSONObject: format)
                    let migrated = try ReviewLoopDocumentMigration.decode(data)
                    XCTAssertEqual(migrated, [loop])
                    let currentData = try JSONEncoder().encode(ReviewLoopsDocument(
                        version: ReviewLoopsDocument.currentVersion, loops: migrated))
                    XCTAssertEqual(try ReviewLoopDocumentMigration.decode(currentData), [loop])
                    let text = String(decoding: currentData, as: UTF8.self)
                    XCTAssertFalse(text.contains("continuationRequested"))
                    XCTAssertFalse(text.contains("reloadContinuationRequested"))
                }
            }
        }
    }

    func testEarlierVerificationTargetsMigrateWithoutLosingRoundHistory() throws {
        var loop = ReviewLoop(id: UUID(), startActionID: "verification", project: project,
                              promptContext: .general, maxRounds: 3, priorityLimit: .p2)
        loop.phase = .paused
        loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread",
                                  fixVerification: ReviewFixVerification(sourceFixTurnID: "fix-turn",
                                                                         targetRevision: "merged-head", turnID: "verify-turn"))]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        var rounds = try XCTUnwrap(saved["rounds"] as? [[String: Any]])
        var verification = try XCTUnwrap(rounds[0]["fixVerification"] as? [String: Any])
        verification["commit"] = verification.removeValue(forKey: "targetRevision")
        rounds[0]["fixVerification"] = verification
        saved["rounds"] = rounds
        for version in [1, 7, 8, 11] {
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "loops": [saved]])
            XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
        }
        let unversioned = try JSONSerialization.data(withJSONObject: [saved])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(unversioned), [loop])
        let current = try JSONEncoder().encode(ReviewLoopsDocument(version: ReviewLoopsDocument.currentVersion, loops: [loop]))
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(current), [loop])
        let currentText = try XCTUnwrap(String(data: current, encoding: .utf8))
        XCTAssertTrue(currentText.contains("\"targetRevision\":\"merged-head\""))
        XCTAssertFalse(currentText.contains("\"commit\":\"merged-head\""))
    }

    func testVersionNineRenamesFocusWithoutLosingSettingsOrHistory() throws {
        var loop = ReviewLoop(id: UUID(), startActionID: "rename", project: project,
                              promptContext: .personal, maxRounds: 3,
                              reviewType: .organisationAndNaming, muteTestPlayback: true)
        loop.phase = .paused
        loop.workspaceRoot = project.path
            loop.workspaceKind = .git
        loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread")]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved["focus"] = saved.removeValue(forKey: "reviewType")
        saved["muteMedia"] = saved.removeValue(forKey: "muteTestPlayback")
        let data = try JSONSerialization.data(withJSONObject: ["version": 9, "loops": [saved]])
        let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
        XCTAssertEqual(migrated, loop)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        XCTAssertNil(current["focus"])
        XCTAssertEqual(current["reviewType"] as? String, "organisationAndNaming")
        let document = try JSONEncoder().encode(ReviewLoopsDocument(version: ReviewLoopsDocument.currentVersion, loops: [migrated]))
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(document), [loop])
    }

    func testVersionTenRenamesPlaybackPreferenceWithoutLosingSettingsOrHistory() throws {
        for enabled in [false, true] {
            var loop = ReviewLoop(id: UUID(), startActionID: "playback", project: project,
                                  promptContext: .personal, maxRounds: 3,
                                  liveTesting: true, muteTestPlayback: enabled)
            loop.phase = .paused
            loop.workspaceRoot = project.path
            loop.workspaceKind = .git
            loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread")]
            var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
            saved["muteMedia"] = saved.removeValue(forKey: "muteTestPlayback")
            let data = try JSONSerialization.data(withJSONObject: ["version": 10, "loops": [saved]])
            let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
            XCTAssertEqual(migrated, loop)
            let current = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
            XCTAssertNil(current["muteMedia"])
            XCTAssertEqual(current["muteTestPlayback"] as? Bool, enabled)
        }
    }

    func testVersionEightAddsMuteTestPlaybackWithoutLosingSavedRound() throws {
        var loop = ReviewLoop(id: UUID(), startActionID: "mute", project: project,
                              promptContext: .personal, maxRounds: 3, liveTesting: true)
        loop.phase = .blocked
        loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread")]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "muteTestPlayback")
        saved["focus"] = saved.removeValue(forKey: "reviewType")
        let data = try JSONSerialization.data(withJSONObject: ["version": 8, "loops": [saved]])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
        loop.muteTestPlayback = true
        let current = try JSONEncoder().encode(ReviewLoopsDocument(version: ReviewLoopsDocument.currentVersion, loops: [loop]))
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(current), [loop])
    }

    func testVersionSevenUnconfirmedStopsKeepTheirCheckoutReservation() throws {
        for (message, expectedPhase) in [
            ("Stopped loop. Stopping its running chat.", ReviewLoopPhase.stopping),
            ("Stopped loop, but could not stop its chat. Open its chat to stop it: offline", .stopping),
            ("Stopped loop and its running chat.", .stopped),
        ] {
            var loop = ReviewLoop(id: UUID(), startActionID: "stop", project: project,
                                  promptContext: .general, maxRounds: 2)
            loop.phase = .stopped
            loop.workspaceRoot = project.path
            loop.workspaceKind = .git
            loop.message = message
            loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread")]
            let data = try JSONEncoder().encode(ReviewLoopsDocument(version: 7, loops: [loop]))
            let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
            XCTAssertEqual(migrated.phase, expectedPhase)
            XCTAssertEqual(migrated.workspaceRoot, project.path)
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
                              promptContext: .personal, maxRounds: 3, reviewType: .bugsAndPerformance,
                              liveTesting: true)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "reloadExtensionBeforeTesting")
        let data = try JSONSerialization.data(withJSONObject: ["version": 4, "loops": [saved]])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
    }

    func testVersionThreeLoopsMigrateWithLiveTestingOff() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "old", project: project,
                              promptContext: .personal, maxRounds: 3, reviewType: .bugsAndPerformance)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved.removeValue(forKey: "liveTesting")
        let data = try JSONSerialization.data(withJSONObject: ["version": 3, "loops": [saved]])
        XCTAssertEqual(try ReviewLoopDocumentMigration.decode(data), [loop])
    }

    func testVersionTwoNamingTypeMigratesToOrganisationAndNaming() throws {
        let (coordinator, _, _) = try make()
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try XCTUnwrap(coordinator.loops.last))) as? [String: Any])
        saved.removeValue(forKey: "reviewType")
        saved["focus"] = "naming"
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "loops": [saved]])
        let migrated = try XCTUnwrap(ReviewLoopDocumentMigration.decode(data).first)
        XCTAssertEqual(migrated.reviewType, .organisationAndNaming)
        XCTAssertEqual(migrated.id, coordinator.loops.last?.id)
        XCTAssertEqual(migrated.project, coordinator.loops.last?.project)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(migrated)) as? [String: Any])
        XCTAssertEqual(current["reviewType"] as? String, "organisationAndNaming")
    }

    func testOlderRoundResultsMigrateAddressedCountsWithoutChangingReviewFindings() throws {
        let (coordinator, _, _) = try make()
        var loop = try XCTUnwrap(coordinator.loops.last)
        var round = ReviewRound(number: 1, baseRevision: "base")
        round.review = ReviewReport(outcome: .reviewed, findings: [
            ReviewFinding(priority: .p2, title: "Issue", body: "Details")
        ], summary: "One finding")
        round.result = ReviewRoundResult(outcome: .fixed, addressedFindingCount: 1,
                                         fixCommit: "fixed", summary: "Done")
        loop.rounds = [round]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        var savedRounds = try XCTUnwrap(saved["rounds"] as? [[String: Any]])
        var savedResult = try XCTUnwrap(savedRounds[0]["result"] as? [String: Any])
        savedResult["commit"] = savedResult.removeValue(forKey: "fixCommit")
        savedResult["findings"] = savedResult.removeValue(forKey: "addressedFindingCount")
        savedRounds[0]["result"] = savedResult
        saved["rounds"] = savedRounds
        let formats: [Any] = [saved, [saved]] + (1...7).map {
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
