import AppKit

@MainActor
final class AccountWindowLauncher {
    private(set) static var presentingProfiles = Set<UUID>()
    func open(accountID: UUID, accounts: AccountCoordinator) async throws {
        guard Self.presentingProfiles.insert(accountID).inserted else { throw AccountWindowError.presentationInProgress }
        defer { Self.presentingProfiles.remove(accountID) }
        guard let account = accounts.savedAccounts.first(where: { $0.id == accountID }),
              let expectedAccountID = account.codexAccountID else {
            throw CodexAccountError.accountIdentityUnavailable
        }
        let profile = AccountWindowProfile(accountID: accountID)
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        )
        if let existing = applications.first(where: {
            CodexConfiguration.processArguments(for: $0.processIdentifier)
                .map { profile.matches(processArguments: $0) } == true
        }) {
            try await AccountWindowPresenter().present(existing, profile: profile)
            return
        }
        let credential = profile.isInitialized ? nil : try await accounts.credentialForSeparateWindow(accountID)
        try profile.prepare(credential: credential, expectedAccountID: expectedAccountID)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = profile.arguments + CodexConfiguration.debugArguments(
            port: CodexConfiguration.randomDevToolsPort()
        )
        configuration.environment = profile.environment
        configuration.activates = true
        let application = try await NSWorkspace.shared.openApplication(
            at: CodexConfiguration.codexApplicationURL, configuration: configuration
        )
        guard !application.isTerminated,
              CodexConfiguration.processArguments(for: application.processIdentifier)
                .map({ profile.matches(processArguments: $0) }) == true else { throw AccountWindowError.launchFailed }
        try await AccountWindowPresenter().present(application, profile: profile)
    }
}
