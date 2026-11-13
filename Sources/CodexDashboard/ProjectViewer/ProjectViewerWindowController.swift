import AppKit
import SwiftUI

@MainActor
final class ProjectViewerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ProjectViewerWindowController()
    let model = ProjectViewerModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Project Viewer — Codex Dashboard"
        window.minSize = NSSize(width: 880, height: 520)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("projectViewer.showFunctions") private var showFunctions = false
    @State private var showFiles = true

    private var canvas: Color { Color(nsColor: ProjectViewerAppearance.background(dark: colorScheme == .dark)) }
    private var sidebar: Color { Color(nsColor: ProjectViewerAppearance.sidebar(dark: colorScheme == .dark)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showFiles.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }.help(showFiles ? "Hide files" : "Show files")
                    .accessibilityLabel("Toggle files sidebar")
                if let root = model.root {
                    Text(root.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .help(root.path)
                } else {
                    Text("Project Viewer").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                if model.root != nil {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh project")
                    Menu {
                        Button("Reset baseline", action: model.resetBaseline)
                            .disabled(model.isScanning || model.baselineDate == nil)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Project actions")
                }
                Button(action: chooseFolder) { Label("Open folder", systemImage: "folder.badge.plus") }
                Button { showFunctions.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }.help(showFunctions ? "Hide functions" : "Show functions")
                    .accessibilityLabel("Toggle functions sidebar")
            }.buttonStyle(ProjectViewerButtonStyle()).controlSize(.small)
                .font(.system(size: 13))
                .padding(.leading, 80).padding(.trailing, 14).frame(height: 52)
            if model.root == nil {
                VStack(spacing: 14) {
                    Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("Your project, at a glance").font(.system(size: 20, weight: .medium))
                    Text("Explore code and follow changes as Codex works.").foregroundStyle(.secondary)
                    Button("Open folder…", action: chooseFolder).buttonStyle(.bordered).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    if showFiles {
                        fileSidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                    }
                    codePane.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                        .background(canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
                        .padding(.leading, 6).padding(.trailing, 12)
                    if showFunctions {
                        functionSidebar.frame(minWidth: 210, idealWidth: 250, maxWidth: 360)
                    }
                }.padding(.bottom, 4)
            }
            if let date = model.baselineDate {
                HStack(spacing: 14) {
                    Label("Read-only", systemImage: "lock").font(.system(size: 10))
                    Text("\(model.files.count) files · \(model.totalLines.formatted()) lines")
                    Text("\(deltaLabel(model.totalDelta)) since baseline")
                    Spacer()
                    Text("Baseline \(date.formatted(date: .omitted, time: .shortened))")
                }.monospacedDigit()
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(sidebar)
            .ignoresSafeArea(.container, edges: .top)
            .tint(.primary)
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { model.changedOnly.toggle() } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(model.changedOnly ? .primary : .secondary)
                        .padding(5)
                        .background(model.changedOnly ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
                    .help(model.changedOnly ? "Show all files" : "Show size changes only")
                    .accessibilityLabel("Size changes only")
                    .accessibilityValue(model.changedOnly ? "On" : "Off")
            }.foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search files", text: $model.filter).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(8)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
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
            }.listStyle(.sidebar).scrollContentBackground(.hidden).font(.system(size: 13))
        }.padding(.horizontal, 12).padding(.top, 8).background(sidebar)
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
                                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.text")
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
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(selected ? Color.primary.opacity(0.07) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .id(path)
                    }
                }
                .padding(7)
            }.scrollIndicators(.hidden)
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
            }
            HStack {
                Text(model.selectedPath ?? "Select a file").font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if let file = model.selectedFile {
                    Text("\(file.lines.map { String($0) } ?? "—") lines · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.vertical, 12)
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
            Text("Functions").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text("Largest first · estimated lines").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                                    Text(row.function.name).font(.system(size: 12, design: .monospaced))
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
                            }.buttonStyle(ProjectViewerButtonStyle()).disabled(row.removed)
                        }
                    }
                }
            }
        }.padding(14).background(sidebar)
    }

    private func fileStatus(_ status: String, at path: String) -> String {
        guard let delta = model.lineDelta(path), delta != 0 else { return status }
        return "\(status) \(deltaLabel(delta))"
    }

    private func deltaLabel(_ value: Int) -> String { value > 0 ? "+\(value.formatted())" : value.formatted() }
}

private struct ProjectViewerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(configuration: configuration)
    }

    private struct HoverSurface: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .padding(6)
                .background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}
