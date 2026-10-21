import Foundation
import XCTest
@testable import CodexDashboard

final class UsageDeadlineNotificationIDTests: XCTestCase {
    func testExistingKeysRoundTripWithoutChangingDeliveryHistory() throws {
        let accountID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let prefix = "codex-dashboard-account-deadline-v2-12345678-1234-1234-1234-123456789abc-"
        for (kind, component) in [(ScheduledUsageNotificationKind.fiveHourReset, "5-hour"),
                                  (.weeklyReset, "weekly"), (.bankedResetExpiry, "banked-reset-expiry")] {
            let key = UsageDeadlineNotificationID(accountID: accountID, kind: kind, leadTimeHours: 1)
            let source = prefix + component + "-1h"
            XCTAssertEqual(key.rawValue, source)
            let update = key.updatingDeadline(to: Date(timeIntervalSinceReferenceDate: 123))
            let fresh = update.refreshed(at: Date(timeIntervalSince1970: 456))
            XCTAssertEqual(update.rawValue, source + "-deadline-update-123")
            XCTAssertEqual(fresh.rawValue, source + "-deadline-update-123-fresh-456")
            for value in [key, update, fresh, key.refreshed(at: Date(timeIntervalSince1970: 456))] {
                let decoded = try XCTUnwrap(UsageDeadlineNotificationID(rawValue: value.rawValue))
                XCTAssertEqual(decoded, value)
                XCTAssertEqual(decoded.sourceIdentifier, source)
                XCTAssertEqual(decoded.group, key.group)
                XCTAssertEqual(decoded.deliveryIdentifier, value.isDeadlineUpdate ? update.rawValue : source)
            }
            XCTAssertFalse(key.isDeadlineUpdate)
            XCTAssertTrue(update.isDeadlineUpdate)
        }
    }

    func testMalformedIdentifiersAreNotTreatedAsDeadlineAlerts() {
        let prefix = "codex-dashboard-account-deadline-v2-12345678-1234-1234-1234-123456789abc-"
        for suffix in ["weekly-0h", "weekly-1h-extra", "unknown-1h", "weekly-1h-fresh-no",
                       "weekly-1h-deadline-update-", "weekly-1h-fresh-1-fresh-2"] {
            XCTAssertNil(UsageDeadlineNotificationID(rawValue: prefix + suffix), suffix)
        }
        XCTAssertNil(UsageDeadlineNotificationID(rawValue: "other"))
        XCTAssertNil(UsageDeadlineNotificationID(rawValue: "codex-dashboard-account-deadline-v2-invalid-weekly-1h"))
    }

    func testGroupingDistinguishesAccountAndDeadlineKindButNotLeadTime() {
        let accountID = UUID()
        let first = UsageDeadlineNotificationID(accountID: accountID, kind: .weeklyReset, leadTimeHours: 72)
        XCTAssertEqual(first.group, UsageDeadlineNotificationID(accountID: accountID, kind: .weeklyReset, leadTimeHours: 1).group)
        XCTAssertNotEqual(first.group, UsageDeadlineNotificationID(accountID: UUID(), kind: .weeklyReset, leadTimeHours: 72).group)
        XCTAssertNotEqual(first.group, UsageDeadlineNotificationID(accountID: accountID, kind: .fiveHourReset, leadTimeHours: 72).group)
    }
}
