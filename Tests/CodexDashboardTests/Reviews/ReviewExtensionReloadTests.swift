import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewExtensionReloadTests: ReviewLoopTestCase {
    func testReviewWaitsAndContinuesInSameChatOnlyAfterConfirmation() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.requestExtensionReload()
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .awaitingExtensionReload)
        XCTAssertTrue(coordinator.loops[0].message.contains("chrome://extensions"))
        XCTAssertEqual(coordinator.loops[0].completedRoundCount, 0)
        XCTAssertNil(coordinator.loops[0].rounds[0].review)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
        // Waiting survives a restart with its instructions and checkout reservation.
        let saved = ReviewLoopsDocument(version: ReviewLoopsDocument.currentVersion, loops: store.loops)
        store.loops = try ReviewLoopDocumentMigration.decode(JSONEncoder().encode(saved))
        let restored = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(restored.loops[0].phase, .awaitingExtensionReload)
        try restored.apply(action(.resume, for: restored), projects: [project])
        XCTAssertTrue(restored.loops[0].rounds[0].extensionReloadContinuationPending)
        XCTAssertFalse(restored.loops[0].rounds[0].allowsFollowUpTurns)
        await restored.advance(using: driver, threads: [])
        await restored.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertFalse(restored.loops[0].rounds[0].extensionReloadContinuationPending)
        XCTAssertTrue(restored.loops[0].rounds[0].allowsFollowUpTurns)
        XCTAssertTrue(driver.prompts.last!.contains("read-only review"))
        XCTAssertEqual(driver.selections.last!, restored.loops[0].reviewSelection)
        driver.review(priorities: [])
        await restored.advance(using: driver, threads: [])
        XCTAssertEqual(restored.loops[0].phase, .completed)
    }

    func testFixContinuationPreservesDirtyWorkAndSupportsRepeatedReloads() async throws {
        let (coordinator, _, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.clean = false
        driver.requestExtensionReload()
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .awaitingExtensionReload)
        XCTAssertEqual(coordinator.loops[0].rounds[0].review?.findings.count, 1)
        for _ in 0..<2 {
            try coordinator.apply(action(.resume, for: coordinator), projects: [project])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertTrue(driver.prompts.last!.contains("Preserve existing changes"))
            XCTAssertEqual(driver.selections.last!, coordinator.loops[0].fixSelection)
            driver.requestExtensionReload()
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops[0].phase, .awaitingExtensionReload)
            XCTAssertEqual(coordinator.loops[0].completedRoundCount, 0)
        }
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        driver.clean = true
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .limitReached)
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(coordinator.loops[0].rounds.count, 1)
    }

    func testChangedCheckoutPreventsReviewContinuation() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.requestExtensionReload()
        await coordinator.advance(using: driver, threads: [])
        driver.commit = "outside-change"
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testReloadHandlingRejectsChangedWorkspaceRootForReviewAndFix() async throws {
        for fixing in [false, true] {
            for changeWhileWaiting in [false, true] {
                let (coordinator, _, driver) = try make()
                await coordinator.advance(using: driver, threads: [])
                if fixing {
                    driver.review(priorities: [.p1])
                    await coordinator.advance(using: driver, threads: [])
                    await coordinator.advance(using: driver, threads: [])
                    driver.clean = false // Unfinished fixes may be dirty, but cannot change checkout.
                }
                driver.requestExtensionReload()
                let submittedCount = driver.prompts.count
                if changeWhileWaiting {
                    await coordinator.advance(using: driver, threads: [])
                    XCTAssertEqual(coordinator.loops[0].phase, .awaitingExtensionReload)
                    try coordinator.apply(action(.resume, for: coordinator), projects: [project])
                }
                driver.workspaceRoot = "/tmp/different-checkout"
                await coordinator.advance(using: driver, threads: [])
                XCTAssertEqual(coordinator.loops[0].phase, .blocked)
                XCTAssertEqual(driver.prompts.count, submittedCount)
                XCTAssertNil(coordinator.loops[0].rounds[0].result)
            }
        }
    }

    func testStopWhileAwaitingReloadReleasesLoopWithoutContinuing() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.requestExtensionReload()
        await coordinator.advance(using: driver, threads: [])
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .stopped)
        XCTAssertEqual(driver.prompts.count, 1)
    }
}
