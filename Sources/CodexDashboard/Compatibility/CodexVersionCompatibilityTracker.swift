import Foundation

struct CodexVersionCompatibilityTracker {
    private static let checkedVersionKey = "lastCheckedCodexVersion"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func updateWasDetected(currentVersion: String?) -> Bool {
        guard let previousVersion = userDefaults.string(forKey: Self.checkedVersionKey),
              let currentVersion
        else { return false }
        return previousVersion != currentVersion
    }

    func markChecked(version: String?) {
        guard let version else { return }
        userDefaults.set(version, forKey: Self.checkedVersionKey)
    }
}
