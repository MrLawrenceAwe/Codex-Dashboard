import AppKit

/// All paths, process actions, and renderer traffic for a secondary window.
@MainActor
final class AccountWindowRuntimeContext {
    let profile: AccountWindowProfile
    let port: DevToolsPortStorage
    let managedWorkspace: ManagedChatWorkspace?

    init(profile: AccountWindowProfile, arguments: String, managedWorkspace: ManagedChatWorkspace? = nil) {
        self.managedWorkspace = managedWorkspace
        self.profile = profile
        port = DevToolsPortStorage(port: CodexConfiguration.devToolsPort(inProcessArguments: arguments)
                                   ?? CodexConfiguration.randomDevToolsPort())
    }

    func matches(arguments: String) -> Bool {
        CodexConfiguration.devToolsPort(inProcessArguments: arguments) == port.port
    }

    func launchEnvironment() throws -> [String: String] {
        try managedWorkspace?.environment(profile.accountID) ?? profile.environment
    }

    func applications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier).filter {
            CodexConfiguration.processArguments(for: $0.processIdentifier)
                .map { profile.matches(processArguments: $0) } == true
        }
    }

    func makeCoordinator() throws -> AppCoordinator {
        let home = profile.codexHome
        let state = (managedWorkspace?.history ?? home).appendingPathComponent("state_5.sqlite")
        let global = home.appendingPathComponent(".codex-global-state.json")
        let auth = home.appendingPathComponent("auth.json")
        let store = PromptLibraryFileStore(documentURL: profile.dashboardDirectory.appendingPathComponent("prompt-library.json"))
        // Seed reusable prompts once; later saves belong to this window.
        if !FileManager.default.fileExists(atPath: store.documentURL.path),
           let prompts = try PromptLibraryFileStore().load() { try store.save(prompts) }
        let endpoint = port
        let renderer = try DashboardRenderer(
            devTools: DevToolsClient(portProvider: { endpoint.port }),
            promptLibraryStore: store,
            reviewLoopStore: ReviewLoopFileStore(url: profile.dashboardDirectory.appendingPathComponent("review-loop.json"))
        )
        let process = CodexProcessController(
            runningApplicationsProvider: { [self] in applications() },
            makeLaunchConfiguration: { [self] in
                endpoint.selectFreshPort { CodexConfiguration.randomDevToolsPort(excluding: $0) }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.arguments = profile.arguments + CodexConfiguration.debugArguments(port: endpoint.port)
                configuration.environment = try launchEnvironment()
                return configuration
            }
        )
        let opener: (@MainActor (UUID, AccountCoordinator) async throws -> Void)?
        if managedWorkspace != nil {
            opener = { id, accounts in try await ManagedChatController.shared.open(id, accounts: accounts) }
        } else { opener = nil }
        return AppCoordinator(
            catalogProvider: CodexThreadCatalogProvider(stateDatabaseURL: state),
            unreadThreadIDProvider: CodexUnreadThreadIDProvider(stateURL: global, identityKeyLoader: {
                guard FileManager.default.fileExists(atPath: auth.path) else { return nil }
                return try CodexUnreadThreadIDProvider.identityKey(from: Data(contentsOf: auth))
            }),
            compatibilityChecker: LocalCodexCompatibilityChecker(stateDatabaseURL: state, globalStateURL: global),
            userDefaults: UserDefaults(suiteName: "local.lawrenceawe.codex-dashboard.window.\(profile.accountID)") ?? .standard,
            codexHome: home,
            pollInactiveAccountUsage: false,
            isAccountWindow: true,
            managedWindow: managedWorkspace != nil,
            accountWindowOpener: opener,
            codexForegrounder: AccountWindowForegroundController(context: self),
            promptLibraryStore: store,
            accountManager: CodexAccountManager(authenticationURL: auth, usageCacheStore:
                AccountUsageFileCache(cacheURL: profile.dashboardDirectory.appendingPathComponent("account-usage.json"))),
            accountUsageProvider: AppServerUsageProvider(codexHomeURL: home),
            runtimeFactory: { _ in try CodexDashboardRuntime(codex: process, renderer: renderer, promptLibraryStore: store) }
        )
    }
}

@MainActor
private final class AccountWindowForegroundController: CodexForegrounding {
    let context: AccountWindowRuntimeContext
    init(context: AccountWindowRuntimeContext) { self.context = context }
    var isCodexFrontmost: Bool {
        if AccountWindowLauncher.presentingProfiles.contains(context.profile.accountID) { return true }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return context.applications().contains { $0.processIdentifier == frontmost.processIdentifier }
    }
    func foregroundCodex() {
        guard let application = context.applications().first else { return }
        Task { try? await AccountWindowPresenter().present(application, profile: context.profile, environment: context.launchEnvironment()) }
    }
}
