import AppKit
import SwiftUI

@MainActor
final class ProjectViewerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ProjectViewerWindowController()
    let model = ProjectViewerModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Project Viewer — Codex Dashboard"
        window.minSize = NSSize(width: 880, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CodexDashboardProjectViewer")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ProjectViewerWindowView(model: model, chooseFolder: { [weak self] in self?.chooseFolder() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(root: URL? = nil, editedPaths: [String]? = nil) {
        let wasVisible = window?.isVisible == true
        if let root {
            if model.root != root.standardizedFileURL.resolvingSymlinksInPath() || !wasVisible {
                model.open(root, editedPaths: editedPaths)
            } else if let editedPaths {
                model.openEditedFiles(editedPaths)
            }
        } else if !wasVisible, model.root != nil { model.resume() }
        if let name = model.root?.lastPathComponent { window?.title = "\(name) — Project Viewer" }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project to view"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(root: url)
        }
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
}

struct ProjectViewerWindowView: View {
    @ObservedObject var model: ProjectViewerModel
    let chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let root = model.root {
                    Text(root.path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if model.root != nil {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(model.files.count) files · \(model.totalLines.formatted()) lines").monospacedDigit()
                        Text("\(deltaLabel(model.totalDelta)) lines since baseline").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh project")
                    Button("Reset baseline", action: model.resetBaseline).disabled(model.isScanning || model.baselineDate == nil)
                }
                Button("Open Folder…", action: chooseFolder)
            }.padding(16).fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.root == nil {
                ContentUnavailableView("No folder open", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    fileSidebar.frame(minWidth: 220, idealWidth: 290, maxWidth: 460)
                    codePane.frame(minWidth: 360, maxWidth: .infinity)
                    functionSidebar.frame(minWidth: 210, idealWidth: 250, maxWidth: 400)
                }
            }
            if let date = model.baselineDate {
                Divider()
                Text("Read-only · Baseline \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Filter files by path", text: $model.filter).textFieldStyle(.roundedBorder)
            Toggle("Only size changes", isOn: $model.changedOnly).font(.caption)
            List(selection: $model.selectedPath) {
                OutlineGroup(model.tree, children: \.children) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.children == nil ? "doc.text" : "folder").foregroundStyle(.secondary)
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                            .strikethrough(node.children == nil && model.files[node.id] == nil)
                        Spacer(minLength: 4)
                        if node.children == nil {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text((model.files[node.id] ?? model.baseline[node.id])?.lines.map { $0.formatted() } ?? "—")
                                    .foregroundStyle(.secondary)
                                if model.files[node.id] == nil {
                                    Text(fileStatus("Removed", at: node.id)).foregroundStyle(.blue)
                                } else if model.baseline[node.id] == nil {
                                    Text(fileStatus("New", at: node.id)).foregroundStyle(.orange)
                                }
                                else if let delta = model.lineDelta(node.id), delta != 0 {
                                    Text(deltaLabel(delta)).foregroundStyle(delta > 0 ? .orange : .blue)
                                }
                            }.font(.caption).monospacedDigit()
                        }
                    }.tag(node.id).help(node.id)
                }
            }.listStyle(.sidebar)
        }.padding(12)
    }

    private var fileTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(model.tabs, id: \.self) { path in
                        let selected = model.selectedPath == path
                        HStack(spacing: 4) {
                            Button {
                                model.selectedPath = path
                            } label: {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 180)
                            }
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help(path)
                            Button {
                                model.closeTab(path)
                            } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .accessibilityLabel("Close \(path)")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .id(path)
                    }
                }
                .padding(5)
            }
            .onChange(of: model.selectedPath, initial: true) {
                if let path = model.selectedPath { proxy.scrollTo(path) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.tabs.isEmpty {
                fileTabs
                Divider()
            }
            HStack {
                Text(model.selectedPath ?? "Select a file").font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if let file = model.selectedFile {
                    Text("\(file.lines.map { String($0) } ?? "—") lines · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
            Divider()
            if let message = model.previewMessage {
                ContentUnavailableView(message, systemImage: "doc")
            } else if model.selectedFile != nil {
                ProjectCodeView(text: model.code, path: model.selectedPath ?? "", semanticTokens: model.semanticTokens, jump: model.jump)
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text")
            }
        }
    }

    private var functionSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FUNCTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Largest first · estimated line counts").font(.caption).foregroundStyle(.secondary)
            if model.functionRows.isEmpty {
                Text("No recognised functions in this file.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.functionRows, id: \.function.id) { row in
                            Button {
                                model.jump(to: row.function.startLine)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.function.name).font(.system(.callout, design: .monospaced))
                                        .lineLimit(2).strikethrough(row.removed)
                                    HStack {
                                        Text("\(row.function.lineCount) lines")
                                        Spacer()
                                        if row.removed {
                                            Text("Removed \(deltaLabel(-row.function.lineCount))").foregroundStyle(.blue)
                                        } else if row.added {
                                            Text("New \(deltaLabel(row.function.lineCount))").foregroundStyle(.orange)
                                        }
                                        else if let delta = row.delta, delta != 0 {
                                            Text(deltaLabel(delta)).foregroundStyle(delta > 0 ? .orange : .blue)
                                        }
                                    }.font(.caption).monospacedDigit()
                                    if !row.removed {
                                        Text("Lines \(row.function.startLine)–\(row.function.endLine)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(row.removed)
                            Divider()
                        }
                    }
                }
            }
        }.padding(12)
    }

    private func fileStatus(_ status: String, at path: String) -> String {
        guard let delta = model.lineDelta(path), delta != 0 else { return status }
        return "\(status) \(deltaLabel(delta))"
    }

    private func deltaLabel(_ value: Int) -> String { value > 0 ? "+\(value.formatted())" : value.formatted() }
}
