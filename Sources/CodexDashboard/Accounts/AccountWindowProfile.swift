import Foundation

/// Persistent storage for one account's independent desktop instance.
struct AccountWindowProfile {
    let accountID: UUID
    let root: URL
    let codexHome: URL
    let desktopData: URL

    init(accountID: UUID, profilesDirectory: URL = CodexConfiguration.dashboardSupportDirectory()
        .appendingPathComponent("account-windows", isDirectory: true)) {
        self.accountID = accountID
        root = profilesDirectory.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        desktopData = root.appendingPathComponent("desktop-profile", isDirectory: true)
    }

    var dashboardDirectory: URL { root.appendingPathComponent("dashboard", isDirectory: true) }

    func matches(processArguments: String) -> Bool {
        processArguments.contains(arguments[0] + " ") || processArguments.hasSuffix(arguments[0])
            || processArguments.hasSuffix(arguments[0] + "\n")
    }

    var arguments: [String] { ["--user-data-dir=\(desktopData.path)"] }
    var environment: [String: String] {
        ["CODEX_HOME": codexHome.path, "CODEX_ELECTRON_USER_DATA_PATH": desktopData.path]
    }

    var isInitialized: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("initialized").path)
    }

    func prepare(credential: Data?, expectedAccountID: String) throws {
        let manager = FileManager.default
        for directory in [root.deletingLastPathComponent(), root, codexHome, desktopData] {
            // Refuse redirected profiles rather than seeding credentials outside this profile.
            if let type = (try? manager.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType,
               type != FileAttributeType.typeDirectory {
                throw AccountWindowError.invalidProfile
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let authURL = codexHome.appendingPathComponent("auth.json")
        if let type = (try? manager.attributesOfItem(atPath: authURL.path)[.type]) as? FileAttributeType,
           type != FileAttributeType.typeRegular { throw AccountWindowError.invalidProfile }
        let auth = ActiveCodexCredentialFile(url: authURL, fileManager: manager)
        if let existing = try auth.read() {
            guard AccountIdentityDecoder.identity(in: existing)?.identifier == expectedAccountID else {
                throw CodexAccountError.credentialAccountMismatch
            }
        } else if !isInitialized {
            guard let credential,
                  AccountIdentityDecoder.identity(in: credential)?.identifier == expectedAccountID else {
                throw CodexAccountError.credentialAccountMismatch
            }
            try auth.write(credential)
        }
        // Do not replace refreshed tokens or silently sign back in after a user signs out.
        if !isInitialized {
            try Data().write(to: root.appendingPathComponent("initialized"), options: .atomic)
        }
    }
}

enum AccountWindowError: LocalizedError {
    case invalidProfile
    case launchFailed
    case windowNotPresented
    case codexModeUnavailable
    case presentationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "The separate account window's storage is not a regular local directory."
        case .presentationInProgress: "This account window is already opening. Wait for that request to finish."
        case .codexModeUnavailable: "The account window opened, but Codex mode is unavailable for this account."
        case .windowNotPresented: "Codex is running, but its account window could not be brought to the front. Use Account Window Dashboards → Restart & Enable if this window was opened before Dashboard support."
        case .launchFailed: "The separate account window could not be confirmed. The main window is unchanged."
        }
    }
}
