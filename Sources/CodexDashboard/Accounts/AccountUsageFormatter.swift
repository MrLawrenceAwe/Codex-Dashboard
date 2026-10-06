import Foundation

enum AccountUsageFormatter {
    static func blockage(for status: CodexAccountUsageStatus) -> AccountUsageBlockage? {
        guard let usage = status.snapshot?.usage else { return nil }
        let windows = [("5-hour", usage.fiveHour), ("Weekly", usage.weekly)].compactMap { label, window in
            guard let window, window.usedPercent >= 100 else { return nil as AccountUsageBlockage.Window? }
            return AccountUsageBlockage.Window(
                label: label,
                resetsAtMilliseconds: window.resetsAt.map { $0.timeIntervalSince1970 * 1_000 }
            )
        }
        guard !windows.isEmpty else { return nil }
        let isStale: Bool
        if case .available = status { isStale = false } else { isStale = true }
        return AccountUsageBlockage(windows: windows, isStale: isStale)
    }

    static func rows(
        for status: CodexAccountUsageStatus,
        now: Date = .now,
        staleTimestampPrefix: String? = "Usage may be stale · updated ",
        includesAbsoluteDate: Bool = true,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [AccountUsageRow] {
        var rows: [AccountUsageRow] = []
        if let snapshot = status.snapshot {
            if let window = snapshot.usage.fiveHour {
                rows.append(windowRow(
                    "5-hour",
                    window: window,
                    now: now,
                    includesAbsoluteDate: includesAbsoluteDate,
                    locale: locale,
                    timeZone: timeZone
                ))
            }
            if let window = snapshot.usage.weekly {
                rows.append(windowRow(
                    "Weekly",
                    window: window,
                    now: now,
                    includesAbsoluteDate: includesAbsoluteDate,
                    locale: locale,
                    timeZone: timeZone
                ))
            }
            if let resets = snapshot.usage.bankedResets {
                var value = "\(max(0, resets.availableCount)) available"
                if resets.availableCount > 0, let expiration = resets.nextExpiration {
                    let deadline = deadlineDescription(
                        expiration,
                        now: now,
                        includesAbsoluteDate: includesAbsoluteDate,
                        locale: locale,
                        timeZone: timeZone
                    )
                    value += " · expires \(deadline)"
                }
                rows.append(AccountUsageRow(label: "Banked resets", value: value))
            }
        }

        switch status {
        case .loading(let previous):
            rows.append(AccountUsageRow(label: nil, value: previous == nil ? "Loading usage details…" : "Updating usage details…"))
        case .available:
            if rows.isEmpty { rows.append(AccountUsageRow(label: nil, value: "Usage details unavailable")) }
        case .stale(let snapshot):
            if let staleTimestampPrefix {
                rows.append(AccountUsageRow(label: nil, value: "\(staleTimestampPrefix)\(timeString(snapshot.fetchedAt))"))
            }
        case .unavailable:
            rows.append(AccountUsageRow(label: nil, value: "Usage details unavailable"))
        }
        return rows
    }

    private static func windowRow(
        _ label: String,
        window: CodexUsageWindow,
        now: Date,
        includesAbsoluteDate: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> AccountUsageRow {
        let remaining = 100 - min(100, max(0, window.usedPercent))
        var value = "\(remaining)% remaining"
        if let resetsAt = window.resetsAt {
            let deadline = deadlineDescription(
                resetsAt,
                now: now,
                includesAbsoluteDate: includesAbsoluteDate,
                locale: locale,
                timeZone: timeZone
            )
            value += " · resets \(deadline)"
        }
        return AccountUsageRow(label: label, value: value)
    }

    private static func deadlineDescription(
        _ date: Date,
        now: Date,
        includesAbsoluteDate: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let relative = relativeTime(until: date, now: now)
        guard includesAbsoluteDate else { return relative }
        let absolute = date.formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                locale: locale,
                timeZone: timeZone
            )
        )
        return "\(relative) (\(absolute))"
    }

    private static func relativeTime(until date: Date, now: Date) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        guard minutes > 0 else { return "now" }
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let remainingMinutes = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if days == 0, remainingMinutes > 0 { parts.append("\(remainingMinutes)m") }
        return "in \(parts.joined(separator: " "))"
    }

    private static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
