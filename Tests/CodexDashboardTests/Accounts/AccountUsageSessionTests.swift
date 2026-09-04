import Foundation
import XCTest
@testable import CodexDashboard

private actor PerAccountUsageProvider: AccountUsageProviding {
    private var requestsByCredential: [Data: Int] = [:]

    func usage() throws -> CodexAccountUsage { throw CancellationError() }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        requestsByCredential[credential, default: 0] += 1
        try await Task.sleep(for: .milliseconds(50))
        return SavedAccountUsageResult(
            usage: CodexAccountUsage(fiveHour: nil, weekly: nil),
            credential: credential
        )
    }

    func reset() {}

    func requestCount(for credential: Data) -> Int {
        requestsByCredential[credential, default: 0]
    }
}

@MainActor
final class AccountUsageSessionTests: XCTestCase {
    func testSavedUsageCoalescesOnlyMatchingAccounts() async throws {
        let provider = PerAccountUsageProvider()
        let cache = UsageCache(
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountUsageSessionTests-\(UUID().uuidString).json")
        )
        let session = AccountUsageSession(provider: provider, cache: cache)
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        let firstCredential = Data("first".utf8)
        let secondCredential = Data("second".utf8)

        async let first = session.fetchUsage(using: firstCredential, for: firstAccountID)
        async let duplicate = session.fetchUsage(using: firstCredential, for: firstAccountID)
        async let second = session.fetchUsage(using: secondCredential, for: secondAccountID)
        _ = try await (first, duplicate, second)

        let firstRequestCount = await provider.requestCount(for: firstCredential)
        let secondRequestCount = await provider.requestCount(for: secondCredential)
        XCTAssertEqual(firstRequestCount, 1)
        XCTAssertEqual(secondRequestCount, 1)
    }
}
