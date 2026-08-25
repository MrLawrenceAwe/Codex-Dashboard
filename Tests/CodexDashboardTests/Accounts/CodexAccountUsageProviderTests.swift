import Foundation
import XCTest

@testable import CodexDashboard

final class CodexAccountUsageProviderTests: XCTestCase {
    func testReadsFiveHourAndWeeklyWindowsFromAppServerResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexAccountUsageProviderTests-\(UUID().uuidString)", isDirectory: true
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
                printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":null,"resetsAt":2000},"secondary":{"usedPercent":41,"windowDurationMins":null,"resetsAt":3000}}}}'
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
        let provider = CodexAppServerAccountUsageProvider(
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
        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
        XCTAssertEqual(requests.components(separatedBy: "\"method\":\"initialize\"").count - 1, 1)
        XCTAssertEqual(requests.components(separatedBy: "rateLimits").count - 1, 2)
    }

    func testTimeoutTerminatesAnUnresponsiveAppServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexAccountUsageProviderTimeoutTests-\(UUID().uuidString)", isDirectory: true
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
        let provider = CodexAppServerAccountUsageProvider(
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
}
