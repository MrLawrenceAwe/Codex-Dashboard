import Foundation

@MainActor
final class PromptLibraryBackupSynchronizer {
    private static let storageKey = "codex-dashboard.prompt-library"
    private static let checkInterval: TimeInterval = 30

    private let store: PromptBackupStore?
    private let now: () -> Date
    private var lastCheck: Date?

    init(store: PromptBackupStore?, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func reset() {
        lastCheck = nil
    }

    func restoreIfNeeded(in target: DevToolsTarget, using devTools: any DevToolsServing) async {
        guard let store,
              let backup = await store.load(),
              let data = try? JSONSerialization.data(withJSONObject: backup, options: .fragmentsAllowed),
              let encodedBackup = String(data: data, encoding: .utf8)
        else { return }
        let expression = """
        (() => {
          const key = '\(Self.storageKey)';
          if (localStorage.getItem(key)) return true;
          localStorage.setItem(key, \(encodedBackup));
          return true;
        })()
        """
        _ = try? await devTools.evaluateBoolean(expression, in: target)
    }

    func backUpIfDue(
        afterMounting mountedDashboard: Bool,
        from target: DevToolsTarget?,
        using devTools: any DevToolsServing
    ) async {
        guard let store, let target, checkIsDue(afterMounting: mountedDashboard) else { return }
        guard let json = try? await devTools.evaluateString(
            "localStorage.getItem('\(Self.storageKey)')",
            in: target
        ) else { return }
        _ = try? await store.save(json)
    }

    private func checkIsDue(afterMounting mountedDashboard: Bool) -> Bool {
        let currentDate = now()
        guard !mountedDashboard, let lastCheck else {
            self.lastCheck = currentDate
            return true
        }
        guard currentDate.timeIntervalSince(lastCheck) >= Self.checkInterval else { return false }
        self.lastCheck = currentDate
        return true
    }
}
