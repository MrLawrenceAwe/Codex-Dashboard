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
            if (!library || typeof library !== 'object' || Array.isArray(library)) return false;
            if (!Array.isArray(library.prompts) || !Array.isArray(library.sections)) return false;
            if (!library.sections.every((section) => typeof section === 'string')) return false;
            if (!library.prompts.every((prompt) => prompt && typeof prompt === 'object'
              && typeof prompt.id === 'string' && typeof prompt.name === 'string'
              && typeof prompt.content === 'string'
              && (prompt.section === undefined || typeof prompt.section === 'string'))) return false;
            return new Set(library.prompts.map((prompt) => prompt.id)).size === library.prompts.length;
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
