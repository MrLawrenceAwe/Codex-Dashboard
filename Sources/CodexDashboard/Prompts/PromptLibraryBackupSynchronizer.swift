import Foundation

@MainActor
final class PromptLibraryBackupSynchronizer {
    private static let storageKey = "codex-dashboard.prompt-library"
    private static let checkInterval: TimeInterval = 30

    private let store: PromptBackupStore?
    private let contractSource: String
    private let now: () -> Date
    private var lastCheck: Date?

    init(
        store: PromptBackupStore?,
        contractSource: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.contractSource = contractSource
        self.now = now
    }

    func reset() {
        lastCheck = nil
    }

    func restoreIfNeeded(in target: DevToolsTarget, using devTools: any DevToolsServing) async throws {
        guard let store,
              let backup = await store.load(),
              let data = try? JSONSerialization.data(withJSONObject: backup, options: .fragmentsAllowed),
              let encodedBackup = String(data: data, encoding: .utf8)
        else { return }
        let validationExpression = """
        (() => {
          const key = '\(Self.storageKey)';
          try {
            const library = JSON.parse(localStorage.getItem(key));
            \(contractSource)
            return promptLibraryContract.isValidLibrary(library);
          } catch (_) {
            return false;
          }
        })()
        """
        if try await devTools.evaluateBoolean(validationExpression, in: target) { return }
        let restoreExpression = """
        (() => {
          const key = '\(Self.storageKey)';
          localStorage.setItem(key, \(encodedBackup));
          return true;
        })()
        """
        guard try await devTools.evaluateBoolean(restoreExpression, in: target) else {
            throw DashboardError.enableFailed("The saved prompt library could not be restored safely.")
        }
    }

    func backupIfDue(
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
