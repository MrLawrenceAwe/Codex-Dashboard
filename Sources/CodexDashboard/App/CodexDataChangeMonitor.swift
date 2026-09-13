import Foundation

@MainActor
final class CodexDataChangeMonitor {
    static let dataRefreshQuietPeriod: Duration = .milliseconds(100)
    static let dataRefreshMaximumDelay: Duration = .seconds(2)
    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

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
    private var dataRefreshTask: Task<Void, Never>?
    private var dataRefreshTaskID: UUID?
    private var dataRefreshGeneration: UInt64 = 0
    private var refreshCatalog: (@MainActor () async -> Void)?
    private var refreshUnread: (@MainActor () async -> Void)?
    private var refreshAccounts: (@MainActor () async -> Void)?
    private let dataRefreshQuietPeriod: Duration
    private let dataRefreshMaximumDelay: Duration

    init(
        dataRefreshQuietPeriod: Duration = CodexDataChangeMonitor.dataRefreshQuietPeriod,
        dataRefreshMaximumDelay: Duration = CodexDataChangeMonitor.dataRefreshMaximumDelay
    ) {
        self.dataRefreshQuietPeriod = dataRefreshQuietPeriod
        self.dataRefreshMaximumDelay = dataRefreshMaximumDelay
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
        unreadSignature = Self.fileSignature(at: unreadStateURL)
        accountMetadataSignature = Self.fileSignature(at: accountMetadataURL)
        authenticationSignature = Self.fileSignature(at: authenticationURL)

        installDataWatches()
    }

    func stop() {
        dataRefreshGeneration &+= 1
        dataRefreshTask?.cancel()
        dataRefreshTask = nil
        dataRefreshTaskID = nil
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
        dataRefreshGeneration &+= 1
        guard dataRefreshTask == nil else { return }
        let taskID = UUID()
        dataRefreshTaskID = taskID
        dataRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var maximumDelayDeadline = ContinuousClock.now + self.dataRefreshMaximumDelay
            while !Task.isCancelled {
                let generationBeforeQuietPeriod = self.dataRefreshGeneration
                let now = ContinuousClock.now
                if now < maximumDelayDeadline {
                    try? await Task.sleep(for: min(
                        self.dataRefreshQuietPeriod,
                        now.duration(to: maximumDelayDeadline)
                    ))
                }
                guard !Task.isCancelled else { break }
                if self.dataRefreshGeneration != generationBeforeQuietPeriod {
                    if ContinuousClock.now < maximumDelayDeadline { continue }
                }

                await self.refreshChangedData()
                guard !Task.isCancelled,
                      self.dataRefreshGeneration != generationBeforeQuietPeriod
                else { break }
                maximumDelayDeadline = ContinuousClock.now + self.dataRefreshMaximumDelay
            }

            if self.dataRefreshTaskID == taskID {
                self.dataRefreshTask = nil
                self.dataRefreshTaskID = nil
            }

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
            let latest = Self.fileSignature(at: unreadStateURL)
            if latest != unreadSignature {
                unreadSignature = latest
                changed = true
                await refreshUnread?()
            }

        }

        var accountStateChanged = false
        if let accountMetadataURL {
            let latest = Self.fileSignature(at: accountMetadataURL)
            if latest != accountMetadataSignature {
                accountMetadataSignature = latest
                changed = true
                accountStateChanged = true
            }

        }

        if let authenticationURL {
            let latest = Self.fileSignature(at: authenticationURL)
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
            database: fileSignature(at: url),
            writeAheadLog: fileSignature(at: URL(fileURLWithPath: url.path + "-wal"))
        )
    }

    private static func fileSignature(at url: URL) -> FileSignature? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        return FileSignature(size: size, modifiedAt: modifiedAt)
    }
}
