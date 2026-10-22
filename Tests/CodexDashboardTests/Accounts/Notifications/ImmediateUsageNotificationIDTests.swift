import XCTest
@testable import CodexDashboard

final class ImmediateUsageNotificationIDTests: XCTestCase {
    func testPersistedIdentifiersKeepTheirEncodingAndTimestampEpochs() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))
        let reset = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let observed = Date(timeIntervalSince1970: 2_000_000_000)
        let cases: [(ImmediateUsageNotificationID.Event, String, Date)] = [
            (.reset(window: .fiveHour, previousReset: reset),
             "limit-reset-12345678-1234-1234-1234-123456789abc-5-hour-800000000", reset),
            (.reset(window: .weekly, previousReset: reset),
             "limit-reset-12345678-1234-1234-1234-123456789abc-weekly-800000000", reset),
            (.threshold(window: .fiveHour, remainingPercent: 20, reset: reset),
             "usage-threshold-12345678-1234-1234-1234-123456789abc-5-hour-20-800000000", reset),
            (.threshold(window: .weekly, remainingPercent: 50, reset: reset),
             "usage-threshold-12345678-1234-1234-1234-123456789abc-weekly-50-800000000", reset),
            (.bankedResetsAdded(observedAt: observed, total: 2),
             "banked-resets-added-12345678-1234-1234-1234-123456789abc-2000000000-2", observed),
        ]
        for (event, suffix, date) in cases {
            let identifier = "codex-dashboard-account-" + suffix
            let value = ImmediateUsageNotificationID(accountID: accountID, event: event)
            XCTAssertEqual(value.rawValue, identifier)
            let parsed = try XCTUnwrap(ImmediateUsageNotificationID(rawValue: identifier))
            XCTAssertEqual(parsed, value)
            XCTAssertEqual(parsed.retentionDate, date)
        }
    }

    func testMalformedIdentifiersAreRejected() {
        let prefix = "codex-dashboard-account-"
        let account = "12345678-1234-1234-1234-123456789abc"
        for suffix in [
            "unknown-\(account)-weekly-800000000",
            "limit-reset-not-a-uuid-weekly-800000000",
            "limit-reset-\(account)-monthly-800000000",
            "limit-reset-\(account)-weekly-not-a-time",
            "usage-threshold-\(account)-weekly-101-800000000",
            "usage-threshold-\(account)-weekly-50",
            "banked-resets-added-\(account)-2000000000",
            "banked-resets-added-\(account)-2000000000-invalid",
        ] {
            XCTAssertNil(ImmediateUsageNotificationID(rawValue: prefix + suffix), suffix)
        }
    }
}
