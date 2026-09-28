import Foundation

@MainActor
final class UsageNotificationUpdateContext {
    let history: UsageNotificationHistory
    private var updateInProgress = false
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []

    init(userDefaults: UserDefaults, channel: UsageNotificationHistory.Channel) {
        history = UsageNotificationHistory(userDefaults: userDefaults, channel: channel)
    }

    func perform(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        now: () -> Date,
        prepare: () -> Bool = { true },
        apply: (UsageNotificationPlanner.Plan, Date) async -> Void
    ) async {
        while updateInProgress {
            await withCheckedContinuation { updateWaiters.append($0) }
        }
        updateInProgress = true
        defer {
            updateInProgress = false
            updateWaiters.forEach { $0.resume() }
            updateWaiters.removeAll()
        }
        guard prepare() else { return }
        let currentDate = now()

        let plan = UsageNotificationPlanner.plan(
            for: accounts,
            usageByAccountID: usageByAccountID,
            previousObservations: history.observations(),
            previousDeadlines: history.deadlines(for: .known),
            sentUpdates: history.deadlines(for: .updates),
            now: currentDate
        )
        history.saveDeadlines(plan.deadlinesWithoutUpdateAlerts, for: .known)
        await apply(plan, currentDate)
    }
}
