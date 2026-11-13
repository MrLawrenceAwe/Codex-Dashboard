import AppKit
import Combine

struct ProjectTreeNode: Identifiable {
    let id: String
    let name: String
    var children: [ProjectTreeNode]?
}

@MainActor
final class ProjectViewerModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var files: [String: ProjectFile] = [:]
    @Published private(set) var baseline: [String: ProjectFile] = [:]
    @Published private(set) var baselineDate: Date?
    @Published private(set) var isScanning = false
    @Published private(set) var message: String?
    @Published private(set) var code = ""
    @Published private(set) var semanticTokens: [ProjectSemanticToken] = []
    @Published private(set) var previewMessage: String?
    @Published private(set) var tabs: [String] = []
    @Published var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue else { return }
            if let selectedPath, selectedFile != nil, !tabs.contains(selectedPath) {
                tabs.append(selectedPath)
            }
            loadPreview()
        }
    }
    @Published var filter = ""
    @Published var changedOnly = false
    @Published private(set) var jump: CodeJump?
    private var monitor: RecursiveProjectChangeMonitor?
    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var refreshPending = false
    private var isOpen = false
    private var generation = UUID()
    private var pendingEditedPaths: [String]?
    private var shouldSelectInitialFile = true

    var selectedFile: ProjectFile? { selectedPath.flatMap { files[$0] ?? baseline[$0] } }
    var totalLines: Int { files.values.compactMap(\.lines).reduce(0, +) }
    var totalDelta: Int { Set(files.keys).union(baseline.keys).compactMap(lineDelta).reduce(0, +) }
    var visiblePaths: [String] {
        Set(files.keys).union(baseline.keys).filter { path in
            (filter.isEmpty || path.localizedCaseInsensitiveContains(filter)) && (!changedOnly || isChanged(path))
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var tree: [ProjectTreeNode] {
        func build(_ paths: [(path: String, parts: [Substring])], prefix: String) -> [ProjectTreeNode] {
            let grouped = Dictionary(grouping: paths, by: { String($0.parts[0]) })
            return grouped.keys.sorted {
                let leftFolder = grouped[$0]!.contains { $0.parts.count > 1 }
                let rightFolder = grouped[$1]!.contains { $0.parts.count > 1 }
                return leftFolder != rightFolder ? leftFolder : $0.localizedStandardCompare($1) == .orderedAscending
            }.map { name in
                let group = grouped[name]!
                let id = prefix.isEmpty ? name : prefix + "/" + name
                let descendants = group.filter { $0.parts.count > 1 }.map { ($0.path, Array($0.parts.dropFirst())) }
                return ProjectTreeNode(id: id, name: name, children: descendants.isEmpty ? nil : build(descendants, prefix: id))
            }
        }
        return build(visiblePaths.map { ($0, $0.split(separator: "/")) }, prefix: "")
    }

    func isChanged(_ path: String) -> Bool {
        guard let current = files[path], let original = baseline[path] else { return true }
        return current.lines != original.lines || current.bytes != original.bytes || Dictionary(uniqueKeysWithValues: current.functions.map { ($0.id, $0.lineCount) }) != Dictionary(uniqueKeysWithValues: original.functions.map { ($0.id, $0.lineCount) })
    }

    func lineDelta(_ path: String) -> Int? {
        guard let current = files[path]?.lines ?? (files[path] == nil ? 0 : nil),
              let original = baseline[path]?.lines ?? (baseline[path] == nil ? 0 : nil) else { return nil }
        return current - original
    }

    func open(_ url: URL, editedPaths: [String]? = nil) {
        stop()
        isOpen = true
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        root = folder
        files = [:]; baseline = [:]; baselineDate = nil
        tabs = []
        pendingEditedPaths = editedPaths
        shouldSelectInitialFile = editedPaths == nil
        selectedPath = nil; code = ""; previewMessage = nil; message = nil
        filter = ""; changedOnly = false
        let token = generation
        monitor = RecursiveProjectChangeMonitor(projectPaths: [folder.path]) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.refresh()
        }
        monitor?.start()
        refresh()
    }

    func resume() {
        guard let root else { return }
        open(root)
    }

    func stop() {
        isOpen = false
        generation = UUID()
        scanTask?.cancel(); scanTask = nil
        previewTask?.cancel(); previewTask = nil
        monitor?.stop(); monitor = nil
        refreshPending = false; isScanning = false
    }

    func refresh() {
        guard isOpen, let root else { return }
        guard scanTask == nil else { refreshPending = true; return }
        let token = generation
        isScanning = true
        let worker = Task.detached(priority: .utility) { try ProjectFileScanner.scan(root: root) }
        scanTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: { worker.cancel() }
            guard let self, token == self.generation else { return }
            self.isScanning = false
            switch result {
            case .success(let scan):
                self.files = Dictionary(uniqueKeysWithValues: scan.files.map { ($0.path, $0) })
                // A partial scan must not claim unvisited files were deleted.
                if !scan.warnings.isEmpty {
                    for (path, file) in self.baseline where self.files[path] == nil { self.files[path] = file }
                }
                self.message = scan.warnings.isEmpty ? nil : scan.warnings.joined(separator: " ")
                if self.baselineDate == nil { self.resetBaseline() }
                if let editedPaths = self.pendingEditedPaths {
                    self.pendingEditedPaths = nil
                    self.applyEditedTabs(editedPaths)
                } else if self.selectedPath == nil, self.tabs.isEmpty, self.shouldSelectInitialFile {
                    self.selectedPath = scan.files.first(where: { $0.lines != nil })?.path
                } else {
                    self.loadPreview(preserveCode: true)
                }
                self.shouldSelectInitialFile = false
            case .failure(let error): self.message = error.localizedDescription
            }
            self.scanTask = nil
            if self.refreshPending { self.refreshPending = false; self.refresh() }
        }
    }

    func openEditedFiles(_ paths: [String]) {
        pendingEditedPaths = paths
        if !isScanning { refresh() }
    }

    private func applyEditedTabs(_ paths: [String]) {
        var seen = Set<String>()
        tabs = paths.filter { files[$0] != nil && seen.insert($0).inserted }
        selectedPath = tabs.first
    }

    func closeTab(_ path: String) {
        guard let index = tabs.firstIndex(of: path) else { return }
        tabs.remove(at: index)
        if selectedPath == path {
            selectedPath = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
    }

    func resetBaseline() {
        baseline = files
        baselineDate = .now
        tabs.removeAll { files[$0] == nil }
        if let selectedPath, files[selectedPath] == nil { self.selectedPath = tabs.first }
    }

    struct CodeJump: Equatable {
        let line: Int
        let id = UUID()
    }

    func jump(to line: Int) { jump = CodeJump(line: line) }

    var functionRows: [(function: ProjectFunction, delta: Int?, removed: Bool, added: Bool)] {
        guard let path = selectedPath else { return [] }
        if let file = files[path], file.lines == nil { return [] }
        let current = files[path]?.functions ?? []
        let original = baseline[path]?.functions ?? []
        let oldByID = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        let currentIDs = Set(current.map(\.id))
        return (current.map { function in
            (function, function.lineCount - (oldByID[function.id]?.lineCount ?? 0), false, oldByID[function.id] == nil)
        } + original.filter { !currentIDs.contains($0.id) }.map { ($0, -$0.lineCount, true, false) })
        .sorted { $0.0.lineCount > $1.0.lineCount }
    }

    private func loadPreview(preserveCode: Bool = false) {
        previewTask?.cancel()
        if !preserveCode { code = ""; jump = nil; semanticTokens = [] }
        previewMessage = nil
        guard let root, let path = selectedPath else { return }
        guard files[path] != nil || baseline[path] != nil else { return }
        guard let file = files[path] else { previewMessage = "This file was removed since the baseline."; return }
        guard file.lines != nil else { previewMessage = file.note; return }
        let token = generation
        let worker = Task.detached(priority: .utility) { () throws -> String in
            let candidate = root.appendingPathComponent(path).resolvingSymlinksInPath()
            guard FileSystemPath.contains(candidate.path, in: root.path) else { throw CocoaError(.fileReadNoPermission) }
            return try ProjectFileScanner.readText(at: candidate)
        }
        previewTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, token == self.generation, path == self.selectedPath else { return }
            switch result {
            case .success(let text):
                if preserveCode, text == self.code, !self.semanticTokens.isEmpty { return }
                if text != self.code {
                    self.semanticTokens = []
                    self.code = text
                }
                let tokens = await ProjectSemanticHighlighting.tokens(text: text, path: root.appendingPathComponent(path).path)
                guard !Task.isCancelled, token == self.generation, path == self.selectedPath else { return }
                self.semanticTokens = tokens
            case .failure(let error): self.previewMessage = error.localizedDescription
            }
        }
    }
}
