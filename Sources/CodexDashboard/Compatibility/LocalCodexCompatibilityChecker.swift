import Foundation

protocol LocalCompatibilityChecking: Sendable {
    func checkLocalContracts() async -> [CompatibilityCheck]
}

actor LocalCodexCompatibilityChecker: LocalCompatibilityChecking {
    private struct SQLiteColumn: Decodable {
        let name: String
    }

    private let applicationURL: URL
    private let stateDatabaseURL: URL
    private let globalStateURL: URL
    private let subprocessTimeout: TimeInterval

    init(
        applicationURL: URL = CodexConfiguration.codexApplicationURL,
        stateDatabaseURL: URL = CodexConfiguration.stateDatabaseURL,
        globalStateURL: URL = CodexConfiguration.globalStateURL,
        subprocessTimeout: TimeInterval = 3
    ) {
        self.applicationURL = applicationURL
        self.stateDatabaseURL = stateDatabaseURL
        self.globalStateURL = globalStateURL
        self.subprocessTimeout = subprocessTimeout
    }

    func checkLocalContracts() async -> [CompatibilityCheck] {
        [
            checkApplication(),
            await checkThreadDatabase(),
            checkUnreadState(),
            await checkRolloutEvents(),
        ]
    }

    private func checkApplication() -> CompatibilityCheck {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            return check(
                "application", "Codex application", .incompatible,
                "Expected Codex at \(applicationURL.path)."
            )
        }
        guard
            let bundle = Bundle(url: applicationURL),
            bundle.bundleIdentifier == CodexConfiguration.bundleIdentifier
        else {
            return check(
                "application", "Codex application", .incompatible,
                "The installed application no longer uses the expected bundle identifier."
            )
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return check(
            "application", "Codex application", .compatible,
            version.map { "Installed Codex \($0) matches the expected application contract." }
                ?? "The installed Codex application matches the expected contract."
        )
    }

    private func checkThreadDatabase() async -> CompatibilityCheck {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return check(
                "thread-database", "Thread catalog", .incompatible,
                "The expected state database is missing: \(stateDatabaseURL.lastPathComponent)."
            )
        }
        do {
            let result = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-readonly", "-json", stateDatabaseURL.path, "PRAGMA table_info(threads);"],
                timeout: subprocessTimeout
            )
            guard result.terminationStatus == 0 else {
                return check(
                    "thread-database", "Thread catalog", .unavailable,
                    "Codex's thread database could not be inspected."
                )
            }
            let columns = Set(try JSONDecoder().decode([SQLiteColumn].self, from: result.standardOutput).map(\.name))
            let required = CodexThreadCatalogProvider.requiredColumnNames
            let missing = required.subtracting(columns).sorted()
            guard missing.isEmpty else {
                return check(
                    "thread-database", "Thread catalog", .incompatible,
                    "Missing required thread columns: \(missing.joined(separator: ", "))."
                )
            }
            return check(
                "thread-database", "Thread catalog", .compatible,
                "The state database and required thread columns are available."
            )
        } catch {
            return check(
                "thread-database", "Thread catalog", .unavailable,
                "The thread schema check failed: \(error.localizedDescription)"
            )
        }
    }

    private func checkUnreadState() -> CompatibilityCheck {
        guard FileManager.default.fileExists(atPath: globalStateURL.path) else {
            return check(
                "unread-state", "Unread state", .incompatible,
                "The expected Codex global-state file is missing."
            )
        }
        do {
            let data = try Data(contentsOf: globalStateURL, options: .mappedIfSafe)
            _ = try CodexUnreadThreadIDProvider.decodeUnreadThreadIDs(from: data)
            return check(
                "unread-state", "Unread state", .compatible,
                "The persisted local unread-thread contract is available."
            )
        } catch {
            return check(
                "unread-state", "Unread state", .incompatible,
                "The global-state file could not be decoded."
            )
        }
    }

    private func checkRolloutEvents() async -> CompatibilityCheck {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return check(
                "rollout-events", "Activity events", .unavailable,
                "Activity events cannot be checked without the thread database."
            )
        }
        do {
            let result = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [
                    "-readonly", "-noheader", stateDatabaseURL.path,
                    "SELECT rollout_path FROM threads WHERE rollout_path <> '' ORDER BY recency_at_ms DESC LIMIT 12;",
                ],
                timeout: subprocessTimeout
            )
            guard result.terminationStatus == 0 else {
                return check(
                    "rollout-events", "Activity events", .unavailable,
                    "Recent activity-log paths could not be read."
                )
            }
            let paths = String(decoding: result.standardOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            guard !paths.isEmpty else {
                return check(
                    "rollout-events", "Activity events", .unavailable,
                    "There are no recent activity logs to inspect."
                )
            }
            var foundLifecycle = false
            var foundFinalResponse = false
            for path in paths {
                guard let data = tail(of: URL(fileURLWithPath: path), maximumBytes: 512 * 1_024) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                foundLifecycle = foundLifecycle || RolloutActivityReader.lifecycleEventTypes.contains {
                    text.contains(#""type":"\#($0)""#)
                }
                foundFinalResponse = foundFinalResponse
                    || text.contains(#""phase":"\#(RolloutActivityReader.finalResponsePhase)""#)
            }
            guard foundLifecycle else {
                return check(
                    "rollout-events", "Activity events", .incompatible,
                    "Recent logs no longer contain recognized task lifecycle events."
                )
            }
            let status: CompatibilityStatus = foundFinalResponse ? .compatible : .warning
            let detail = foundFinalResponse
                ? "Recent logs contain recognized lifecycle and final-response events."
                : "Lifecycle events are recognized, but no recent final-response marker was found."
            return check("rollout-events", "Activity events", status, detail)
        } catch {
            return check(
                "rollout-events", "Activity events", .unavailable,
                "The activity-log check failed: \(error.localizedDescription)"
            )
        }
    }

    private func tail(of url: URL, maximumBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else {
            return nil
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > maximumBytes ? size - maximumBytes : 0)
        return try? handle.readToEnd()
    }

    private func check(
        _ id: String,
        _ title: String,
        _ status: CompatibilityStatus,
        _ detail: String
    ) -> CompatibilityCheck {
        CompatibilityCheck(id: id, title: title, status: status, detail: detail)
    }
}
