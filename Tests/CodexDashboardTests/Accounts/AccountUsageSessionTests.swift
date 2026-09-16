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
    func testInvalidationReturnsWhileResetIsPendingAndNewUsageWaitsForReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredUsageResetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SuspendedResetUsageProvider()
        let coordinator = AccountCoordinator(
            manager: CodexAccountManager(
                metadataURL: directory.appendingPathComponent("accounts.json"),
                authenticationURL: directory.appendingPathComponent("auth.json")
            ),
            usageProvider: provider
        )

        coordinator.invalidateUsage()
        for _ in 0..<100 {
            if await provider.isResetting() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isResetting = await provider.isResetting()
        XCTAssertTrue(isResetting)
        guard isResetting else { return }
        let refresh = Task { await coordinator.refreshActiveUsage(codexIsRunning: true) }
        await Task.yield()
        let requestsBeforeReset = await provider.requestCount()
        XCTAssertEqual(requestsBeforeReset, 0)
        await provider.finishReset()
        await refresh.value
        let requestsAfterReset = await provider.requestCount()
        XCTAssertEqual(requestsAfterReset, 1)
    }

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

private actor SuspendedResetUsageProvider: AccountUsageProviding {
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private var requests = 0

    func reset() async {
        await withCheckedContinuation { resetContinuation = $0 }
    }

    func usage() -> CodexAccountUsage {
        requests += 1
        return CodexAccountUsage(fiveHour: nil, weekly: nil)
    }

    func usage(using credential: Data) -> SavedAccountUsageResult {
        SavedAccountUsageResult(usage: usage(), credential: credential)
    }

    func isResetting() -> Bool { resetContinuation != nil }
    func requestCount() -> Int { requests }
    func finishReset() {
        resetContinuation?.resume()
        resetContinuation = nil
    }
}
