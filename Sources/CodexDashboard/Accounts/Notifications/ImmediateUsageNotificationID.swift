import Foundation

/// Owns immediate-alert keys and their retention dates. Encodings remain stable
/// because persisted delivery history prevents duplicate desktop and phone alerts.
struct ImmediateUsageNotificationID: Equatable, Sendable {
    enum Window: String, CaseIterable, Sendable {
        case fiveHour = "5-hour", weekly
    }

    enum Event: Equatable, Sendable {
        case reset(window: Window, previousReset: Date)
        case threshold(window: Window, remainingPercent: Int, reset: Date)
        case bankedResetsAdded(observedAt: Date, total: Int)
    }

    private enum Kind: String, CaseIterable {
        case reset = "codex-dashboard-account-limit-reset-"
        case threshold = "codex-dashboard-account-usage-threshold-"
        case bankedResetsAdded = "codex-dashboard-account-banked-resets-added-"
    }

    let accountID: UUID
    let event: Event

    var retentionDate: Date {
        switch event {
        case .reset(_, let date), .threshold(_, _, let date):
            Date(timeIntervalSinceReferenceDate: TimeInterval(Int(date.timeIntervalSinceReferenceDate)))
        case .bankedResetsAdded(let date, _):
            Date(timeIntervalSince1970: TimeInterval(Int(date.timeIntervalSince1970)))
        }
    }

    var rawValue: String {
        let kind: Kind
        let suffix: String
        switch event {
        case .reset(let window, let date):
            kind = .reset
            suffix = "\(window.rawValue)-\(Int(date.timeIntervalSinceReferenceDate))"
        case .threshold(let window, let remainingPercent, let date):
            kind = .threshold
            suffix = "\(window.rawValue)-\(remainingPercent)-\(Int(date.timeIntervalSinceReferenceDate))"
        case .bankedResetsAdded(let date, let total):
            kind = .bankedResetsAdded
            suffix = "\(Int(date.timeIntervalSince1970))-\(total)"
        }
        return kind.rawValue + accountID.uuidString.lowercased() + "-" + suffix
    }

    init(accountID: UUID, event: Event) {
        self.accountID = accountID
        self.event = event
    }

    init?(rawValue: String) {
        guard let kind = Kind.allCases.first(where: { rawValue.hasPrefix($0.rawValue) }) else { return nil }
        let suffix = rawValue.dropFirst(kind.rawValue.count)
        guard let accountID = UUID(uuidString: String(suffix.prefix(36))),
              suffix.dropFirst(36).first == "-" else { return nil }
        let details = String(suffix.dropFirst(37))
        let event: Event
        switch kind {
        case .bankedResetsAdded:
            guard let separator = details.lastIndex(of: "-"),
                  let timestamp = Int(details[..<separator]),
                  let total = Int(details[details.index(after: separator)...]), total >= 0 else { return nil }
            event = .bankedResetsAdded(observedAt: Date(timeIntervalSince1970: TimeInterval(timestamp)), total: total)
        case .reset, .threshold:
            guard let window = Window.allCases.first(where: { details.hasPrefix($0.rawValue + "-") }) else { return nil }
            let value = details.dropFirst(window.rawValue.count + 1)
            if case .reset = kind {
                guard let timestamp = Int(value) else { return nil }
                event = .reset(window: window, previousReset: Date(timeIntervalSinceReferenceDate: TimeInterval(timestamp)))
            } else {
                guard let separator = value.firstIndex(of: "-"),
                      let percent = Int(value[..<separator]), (0...100).contains(percent),
                      let timestamp = Int(value[value.index(after: separator)...]) else { return nil }
                event = .threshold(window: window, remainingPercent: percent,
                                   reset: Date(timeIntervalSinceReferenceDate: TimeInterval(timestamp)))
            }
        }
        self.init(accountID: accountID, event: event)
    }
}
