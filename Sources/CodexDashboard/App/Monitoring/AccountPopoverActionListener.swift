import Foundation

@MainActor
final class AccountPopoverActionListener {
    enum Schedule {
        static func unavailableRetry(active: Bool) -> Duration {
            active ? .seconds(10) : .seconds(60)
        }
    }

    private var task: Task<Void, Never>?

    func start(
        handleAction: @escaping @MainActor () async -> AccountPopoverActionHandlingOutcome
    ) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                let outcome = await handleAction()
                if outcome == .unavailable {
                    try? await Task.sleep(for: Schedule.unavailableRetry(
                        active: RefreshScheduler.isUserActive
                    ))
                } else if outcome == .timedOut {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
