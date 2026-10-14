import Foundation

@MainActor
final class CodexDataChangeMonitor {
    static let dataRefreshQuietPeriod: Duration = .milliseconds(100)
    static let dataRefreshMaximumDelay: Duration = .seconds(2)
    private struct CatalogSignature: Equatable {
        let database: FileSignature?
        let writeAheadLog: FileSignature?
    }

    private var dataWatches: [DispatchSourceFileSystemObject] = []
    private var catalogURL: URL?
    private var unreadStateURL: URL?
    private var accountMetadataURL: URL?
    private var authenticationURL: URL?
    private var catalogSignature: CatalogSignature?
    private var unreadSignature: FileSignature?
    private var accountMetadataSignature: FileSignature?
    private var authenticationSignature: FileSignature?
    private let refreshDebouncer: RefreshDebouncer
    private var refreshCatalog: (@MainActor () async -> Void)?
    private var refreshUnread: (@MainActor () async -> Void)?
    private var refreshAccounts: (@MainActor () async -> Void)?

    init(
        dataRefreshQuietPeriod: Duration = CodexDataChangeMonitor.dataRefreshQuietPeriod,
        dataRefreshMaximumDelay: Duration = CodexDataChangeMonitor.dataRefreshMaximumDelay
    ) {
        refreshDebouncer = RefreshDebouncer(
            quietPeriod: dataRefreshQuietPeriod,
            maximumDelay: dataRefreshMaximumDelay
        )
    }

    func start(
        catalogURL: URL,
        unreadStateURL: URL,
        accountMetadataURL: URL,
        authenticationURL: URL,
        refreshCatalog: @escaping @MainActor () async -> Void,
        refreshUnread: @escaping @MainActor () async -> Void,
        refreshAccounts: @escaping @MainActor () async -> Void
    ) {
        stop()
        self.catalogURL = catalogURL
        self.unreadStateURL = unreadStateURL
        self.accountMetadataURL = accountMetadataURL
        self.authenticationURL = authenticationURL
        self.refreshCatalog = refreshCatalog
        self.refreshUnread = refreshUnread
        self.refreshAccounts = refreshAccounts
        catalogSignature = Self.catalogSignature(at: catalogURL)
        unreadSignature = try? FileSignature.read(at: unreadStateURL)
        accountMetadataSignature = try? FileSignature.read(at: accountMetadataURL)
        authenticationSignature = try? FileSignature.read(at: authenticationURL)

        installDataWatches()
    }

    func stop() {
        refreshDebouncer.cancel()
        FileSystemWatch.cancel(&dataWatches)
        catalogURL = nil
        unreadStateURL = nil
        accountMetadataURL = nil
        authenticationURL = nil
        catalogSignature = nil
        unreadSignature = nil
        accountMetadataSignature = nil
        authenticationSignature = nil
        refreshCatalog = nil
        refreshUnread = nil
        refreshAccounts = nil
    }

    private func scheduleDataRefresh() {
        refreshDebouncer.schedule { [weak self] in
            await self?.refreshChangedData()
        }
    }

    private func refreshChangedData() async {
        var changed = false
        if let catalogURL {
            let latest = Self.catalogSignature(at: catalogURL)
            if latest != catalogSignature {
                catalogSignature = latest
                changed = true
                await refreshCatalog?()
            }

        }

        if let unreadStateURL {
            let latest = try? FileSignature.read(at: unreadStateURL)
            if latest != unreadSignature {
                unreadSignature = latest
                changed = true
                await refreshUnread?()
            }

        }

        var accountStateChanged = false
        if let accountMetadataURL {
            let latest = try? FileSignature.read(at: accountMetadataURL)
            if latest != accountMetadataSignature {
                accountMetadataSignature = latest
                changed = true
                accountStateChanged = true
            }

        }

        if let authenticationURL {
            let latest = try? FileSignature.read(at: authenticationURL)
            if latest != authenticationSignature {
                authenticationSignature = latest
                changed = true
                accountStateChanged = true
            }

        }

        if accountStateChanged { await refreshAccounts?() }
        if changed { installDataWatches() }
    }

    private func installDataWatches() {
        FileSystemWatch.cancel(&dataWatches)
        guard
            let catalogURL,
            let unreadStateURL,
            let accountMetadataURL,
            let authenticationURL
        else { return }
        let writeAheadLogURL = URL(fileURLWithPath: catalogURL.path + "-wal")
        let candidates = Set([
            catalogURL.deletingLastPathComponent(),
            unreadStateURL.deletingLastPathComponent(),
            accountMetadataURL.deletingLastPathComponent(),
            authenticationURL.deletingLastPathComponent(),
            catalogURL,
            writeAheadLogURL,
            unreadStateURL,
            accountMetadataURL,
            authenticationURL,
        ]).filter { FileManager.default.fileExists(atPath: $0.path) }
        dataWatches = candidates.compactMap { url in
            FileSystemWatch.make(for: url) { [weak self] in self?.scheduleDataRefresh() }
        }

    }
    private static func catalogSignature(at url: URL) -> CatalogSignature {
        CatalogSignature(
            database: try? FileSignature.read(at: url),
            writeAheadLog: try? FileSignature.read(at: URL(fileURLWithPath: url.path + "-wal"))
        )
    }
}
