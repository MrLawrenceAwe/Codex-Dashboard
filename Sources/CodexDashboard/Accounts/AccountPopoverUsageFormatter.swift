import Foundation

enum AccountPopoverUsageFormatter {
    static func titles(
        for status: CodexAccountUsageStatus,
        staleLabel: String,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [String] {
        AccountUsageMenuFormatter.titles(
            for: status,
            now: now,
            staleLabel: staleLabel,
            includesAbsoluteDate: false,
            locale: locale,
            timeZone: timeZone
        )
    }
}
