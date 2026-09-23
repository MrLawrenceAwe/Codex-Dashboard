import Foundation
import XCTest

@testable import CodexDashboard

final class AppServerUsageProviderTests: XCTestCase {
    func testKnownWindowDurationDoesNotBecomeTheOtherLimit() {
        let weekly = RateLimitWindow(usedPercent: 70, windowDurationMins: 10_080, resetsAt: 2_000)
        let usage = RateLimitSnapshot(primary: weekly, secondary: nil).accountUsage(bankedResets: nil)

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.weekly?.usedPercent, 70)
    }

    func testRevokedOAuthTokenHasAnActionableError() {
        let rawMessage = #"failed to fetch codex rate limits: 401 Unauthorized; body={"error":{"message":"Encountered invalidated oauth token for user, failing request","code":"token_revoked"}}"#

        let error = CodexAccountUsageError(serverMessage: rawMessage)

        guard case .authenticationExpired = error else {
            return XCTFail("Expected a revoked token to be classified as an expired sign-in")
        }
        XCTAssertEqual(
            error.localizedDescription,
            "Sign-in expired. Select Sign in to authenticate this account again."
        )
        XCTAssertFalse(error.localizedDescription.contains("token_revoked"))
        XCTAssertFalse(error.localizedDescription.contains("401"))
    }

    func testOtherAppServerErrorsKeepTheirMessage() {
        let error = CodexAccountUsageError(serverMessage: "Service is warming up")

        guard case .server(let message) = error else {
            return XCTFail("Expected a regular server error")
        }
        XCTAssertEqual(message, "Service is warming up")
        XCTAssertEqual(
            error.localizedDescription,
            "Codex could not read account usage: Service is warming up"
        )
    }

    func testReadsFiveHourAndWeeklyWindowsFromAppServerResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppServerUsageProviderTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("fake-codex")
        let requestsURL = directory.appendingPathComponent("requests.log")
        let script = #"""
        #!/bin/sh
        initialized=0
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "\#(requestsURL.path)"
          case "$line" in
            *rateLimits*)
              if [ "$initialized" = 1 ]; then
                printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":null,"resetsAt":2000},"secondary":{"usedPercent":41,"windowDurationMins":null,"resetsAt":3000}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"later","resetType":"codexRateLimits","status":"available","grantedAt":1000,"expiresAt":5000},{"id":"sooner","resetType":"codexRateLimits","status":"available","grantedAt":1000,"expiresAt":4000}]}}}'
              fi
              ;;
            *initialized*)
              initialized=1
              ;;
            *initialize*)
              printf '%s\n' '{"id":1,"result":{"userAgent":"test","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executableURL.path
        )
        let provider = AppServerUsageProvider(
            executableURL: executableURL,
            codexHomeURL: directory,
            timeout: .seconds(1)
        )

        let usage = try await provider.usage()
        _ = try await provider.usage()

        XCTAssertEqual(usage.fiveHour?.usedPercent, 17)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(usage.weekly?.usedPercent, 41)
        XCTAssertEqual(usage.weekly?.resetsAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(usage.bankedResets?.availableCount, 2)
        XCTAssertEqual(usage.bankedResets?.nextExpiration, Date(timeIntervalSince1970: 4_000))
        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
        XCTAssertEqual(requests.components(separatedBy: "\"method\":\"initialize\"").count - 1, 1)
        XCTAssertEqual(requests.components(separatedBy: "rateLimits").count - 1, 2)
    }

    func testTimeoutTerminatesAnUnresponsiveAppServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppServerUsageProviderTimeoutTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *initialize*)
              printf '%s\n' '{"id":1,"result":{}}'
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executableURL.path
        )
        let provider = AppServerUsageProvider(
            executableURL: executableURL,
            codexHomeURL: directory,
            timeout: .milliseconds(100)
        )

        do {
            _ = try await provider.usage()
            XCTFail("Expected the usage request to time out")
        } catch {
            XCTAssertNotNil(error as? CodexAccountUsageError)
        }
    }

    func testSavedAccountUsageUsesAndRemovesAnIsolatedHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexSavedAccountUsageProviderTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("fake-codex")
        let observedHomeURL = directory.appendingPathComponent("observed-home.txt")
        let activeHome = directory.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        let activeCredential = Data(#"{"account":"active"}"#.utf8)
        try activeCredential.write(to: activeHome.appendingPathComponent("auth.json"))
        let script = #"""
        #!/bin/sh
        printf '%s' "$CODEX_HOME" > "\#(observedHomeURL.path)"
        initialized=0
        while IFS= read -r line; do
          case "$line" in
            *rateLimits*)
              if [ "$initialized" = 1 ]; then
                printf '%s' '{"account":"saved-refreshed"}' > "$CODEX_HOME/auth.json"
                printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":null,"resetsAt":null},"secondary":null},"rateLimitResetCredits":null}}'
              fi
              ;;
            *initialized*)
              initialized=1
              ;;
            *initialize*)
              printf '%s\n' '{"id":1,"result":{}}'
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executableURL.path
        )
        let provider = AppServerUsageProvider(
            executableURL: executableURL,
            codexHomeURL: activeHome,
            timeout: .seconds(1)
        )

        let result = try await provider.usage(
            using: Data(#"{"account":"saved"}"#.utf8)
        )

        XCTAssertEqual(result.usage.fiveHour?.usedPercent, 12)
        XCTAssertEqual(result.credential, Data(#"{"account":"saved-refreshed"}"#.utf8))
        XCTAssertEqual(
            try Data(contentsOf: activeHome.appendingPathComponent("auth.json")),
            activeCredential
        )
        let observedHome = try String(contentsOf: observedHomeURL, encoding: .utf8)
        XCTAssertNotEqual(observedHome, activeHome.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: observedHome))
    }
}
