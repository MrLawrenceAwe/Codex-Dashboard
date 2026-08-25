import Foundation

enum AccountUsageMenuFormatter {
    static func titles(
        for status: CodexAccountUsageStatus,
        now: Date = .now,
        staleLabel: String = "Usage may be stale"
    ) -> [String] {
        var titles: [String] = []
        if let snapshot = status.snapshot {
            if let window = snapshot.usage.fiveHour {
                titles.append(windowTitle("5-hour", window: window, now: now))
            }
            if let window = snapshot.usage.weekly {
                titles.append(windowTitle("Weekly", window: window, now: now))
            }
            if let resets = snapshot.usage.bankedResets {
                var title = "Banked resets: \(max(0, resets.availableCount)) available"
                if resets.availableCount > 0, let expiration = resets.nextExpiration {
                    title += " · next expires \(relativeTime(until: expiration, now: now))"
                }
                titles.append(title)
            }
        }

        switch status {
        case .loading(let previous):
            titles.append(previous == nil ? "Loading usage details…" : "Updating usage details…")
        case .available:
            if titles.isEmpty { titles.append("Usage details unavailable") }
        case .stale(let snapshot):
            titles.append("\(staleLabel) · updated \(timeString(snapshot.fetchedAt))")
        case .unavailable:
            titles.append("Usage details unavailable")
        }
        return titles
    }

    private static func windowTitle(
        _ label: String,
        window: CodexUsageWindow,
        now: Date
    ) -> String {
        let remaining = 100 - min(100, max(0, window.usedPercent))
        var title = "\(label): \(remaining)% remaining"
        if let resetsAt = window.resetsAt {
            title += " · resets \(relativeTime(until: resetsAt, now: now))"
        }
        return title
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
