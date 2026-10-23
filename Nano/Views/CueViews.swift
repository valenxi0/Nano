import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CueStyle {
    static let accent = Color(red: 0.31, green: 0.49, blue: 1.0)
    static let hairline = Color.white.opacity(0.07)

    static func tint(for kind: CueKind) -> Color {
        switch kind {
        case .todo: Color(red: 0.58, green: 0.85, blue: 0.68)
        case .prompt: Color(red: 0.84, green: 0.66, blue: 0.96)
        case .idea: Color(red: 1.00, green: 0.77, blue: 0.48)
        case .link: Color(red: 0.62, green: 0.71, blue: 1.00)
        }
    }
}

extension CueFolder {
    var color: Color {
        let rgb = Self.palette[colorIndex % Self.palette.count]
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Project directories that agents have worked in recently, newest first.
/// Offered as one-click links for Cue folders.
@MainActor
enum CueRecentProjects {
    static func directories(from sessions: AgentSessionStore, limit: Int = 8) -> [String] {
        projects(in: sessions.sessions.compactMap(\.workingDirectory), limit: limit)
    }

    /// A project is a git repository. A session in a subfolder or a worktree
    /// counts as its repository; the scratch folders that projectless chats
    /// run in (`~/.t3/scratch`, `~/Documents/Codex`) are not repositories.
    nonisolated static func projects(in directories: [String], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for directory in directories where result.count < limit {
            guard !directory.isEmpty, let path = repository(containing: directory),
                  !isTemporary(path), seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    private nonisolated static func isTemporary(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        return roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    /// The nearest folder at or above `path` holding `.git`. A linked
    /// worktree's `.git` is a file pointing into the main repository's
    /// `.git/worktrees/<name>`, and resolves to that repository.
    private nonisolated static func repository(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/", url.path != NSHomeDirectory() {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return url.path }
                guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                      pointer.hasPrefix("gitdir:") else { return nil }
                let gitDirectory = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let range = gitDirectory.range(of: "/.git/worktrees/") else { return nil }
                let main = String(gitDirectory[..<range.lowerBound])
                return FileManager.default.fileExists(atPath: main) ? main : nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func chooseDirectory(_ completion: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Choose the project folder. Cue shows its path next to the folder's name."
        // The island floats above ordinary windows; the sheet has to as well.
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url.path) }
        }
    }
}

extension NanoSettings {
    /// How a capture starts from another app, as it is set up right now.
    /// Nil when the shortcut is turned off.
    var cueCaptureGesture: String? {
        cueQuickCaptureEnabled ? "Press \(cueQuickCaptureHotkey.displayString)" : nil
    }
}

// MARK: - Module

struct CueModuleView: View {
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if store.draft != nil {
                CueCaptureView(store: store, viewModel: viewModel)
                    .transition(.opacity)
            } else {
                CueLibraryView(store: store, viewModel: viewModel)
                    .transition(.opacity)
            }

            if let toast = store.toast, store.draft == nil {
                CueToastView(toast: toast, store: store)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: store.draft == nil)
        .animation(.easeOut(duration: 0.18), value: store.toast)
        .onDisappear {
            if store.draft?.isEmpty == true { store.cancelDraft() }
            store.editingItemID = nil
            store.searchQuery = ""
        }
    }
}

private struct CueToastView: View {
    let toast: CueToast
    @ObservedObject var store: CueStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CueStyle.accent)
            Text(toast.message)
                .font(.system(size: 11.5, weight: .medium))
            if toast.isUndoable {
                Button("Undo") { store.undoToast() }
                    .buttonStyle(.nanoPress)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.62, green: 0.71, blue: 1.0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.11, green: 0.11, blue: 0.14), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }
}

// MARK: - Capture

private struct CueCaptureView: View {
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel
    @State private var focusToken = 0

    private var draft: CueDraft? { store.draft }

    private var text: Binding<String> {
        Binding(
            get: { store.draft?.text ?? "" },
            set: { store.draft?.text = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            editor
            chips
            footer
        }
        .onAppear { requestFocus() }
        .onReceive(NotificationCenter.default.publisher(for: .nanoIslandWantsKeyboard)) { _ in
            requestFocus()
        }
    }

    private func requestFocus() {
        // The panel becomes key a beat after the shortcut; focus after it does.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            focusToken += 1
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                CueTextView(
                    text: text,
                    fontSize: 14,
                    focusToken: focusToken,
                    onSubmit: { keepOpen in
                        guard draft?.isEmpty == false else { return }
                        viewModel.finishCueCapture(save: true, keepOpen: keepOpen)
                        if keepOpen { focusToken += 1 }
                    },
                    onCancel: { viewModel.finishCueCapture(save: false) },
                    onImages: { store.draft?.images.append(contentsOf: $0) }
                )
                if draft?.text.isEmpty != false {
                    Text(draft?.images.isEmpty == false ? "Add a line of context…" : "What do you need to remember?")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }

            if let images = draft?.images, !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                            draftThumb(data, index: index)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: 72)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(CueStyle.accent.opacity(0.55), lineWidth: 1)
        }
    }

    private func draftThumb(_ data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 0.75)
                    }
            }
            Button {
                store.draft?.images.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.nanoPress)
            .padding(4)
            .help("Remove image")
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            if let source = draft?.sourceApp {
                CueChip(
                    text: draft?.pulledFromSelection == true ? "From selection · \(source)" : "From \(source)",
                    tint: CueStyle.accent
                )
            }

            Menu {
                Button("Automatic (\(CueKind.guess(for: draft?.text ?? "").title))") { store.draft?.kind = nil }
                Divider()
                ForEach(CueKind.allCases) { kind in
                    Button(kind.title) { store.draft?.kind = kind }
                }
            } label: {
                CueChip(text: draft?.resolvedKind.title ?? "To-do", tint: CueStyle.tint(for: draft?.resolvedKind ?? .todo), showsChevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What kind of cue this is")

            CueScopeMenu(store: store, selection: Binding(
                get: { store.draft?.scope ?? .inbox },
                set: { store.draft?.scope = $0 }
            ))

            if NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
                Button {
                    store.draft?.images.append(contentsOf: CueStore.imageData(from: .general))
                } label: {
                    CueChip(text: "Add clipboard image", symbol: "photo")
                }
                .buttonStyle(.nanoPress)
            }

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                hint("⏎", "Save")
                hint("⇧⏎", "New line")
                hint("⌘⏎", "Save and add another")
                hint("esc", "Cancel")
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel") { viewModel.finishCueCapture(save: false) }
                .buttonStyle(CuePillButtonStyle())
            Button("Save") { viewModel.finishCueCapture(save: true) }
                .buttonStyle(CuePillButtonStyle(prominent: true))
                .disabled(draft?.isEmpty != false)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.42))
    }
}

/// Folder picker shared by the capture chips and the item menu.
private struct CueScopeMenu: View {
    @ObservedObject var store: CueStore
    @Binding var selection: CueScope

    var body: some View {
        Menu {
            Button("Inbox") { selection = .inbox }
            ForEach(CueFolderSection.allCases) { section in
                let folders = store.folders(in: section)
                if !folders.isEmpty {
                    Section(section.title) {
                        ForEach(folders) { folder in
                            Button(folder.name) { selection = .folder(folder.id) }
                        }
                    }
                }
            }
        } label: {
            CueChip(
                text: store.title(for: selection),
                dot: store.folder(selection.folderID)?.color,
                showsChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Folder")
    }
}

struct CueChip: View {
    let text: String
    var tint: Color?
    var dot: Color?
    var symbol: String?
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .opacity(0.5)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint.map { $0.opacity(0.95) } ?? .white.opacity(0.8))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background((tint ?? .white).opacity(tint == nil ? 0.07 : 0.15), in: Capsule())
        .contentShape(Capsule())
    }
}

struct CuePillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                prominent ? CueStyle.accent.opacity(isEnabled ? 1 : 0.35) : .white.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(
                configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8) : .spring(response: 0.28, dampingFraction: 0.72),
                value: configuration.isPressed
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Library

private struct CueLibraryView: View {
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel

    @State private var draggingID: UUID?
    @State private var newFolderSection: CueFolderSection?
    @State private var newFolderName = ""
    @State private var renamingFolderID: UUID?
    @State private var renameText = ""
    @State private var dropTargeted = false
    @FocusState private var folderFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 172)
            Rectangle()
                .fill(CueStyle.hairline)
                .frame(width: 1)
                .padding(.vertical, 2)
            main
                .padding(.leading, 14)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                scopeRow(.inbox, name: "Inbox", color: nil, linked: false)

                ForEach(CueFolderSection.allCases) { section in
                    sectionHeader(section)
                    ForEach(store.folders(in: section)) { folder in
                        folderRow(folder)
                    }
                    if newFolderSection == section {
                        newFolderField(section)
                    }
                }
            }
            .padding(.trailing, 10)
        }
    }

    private func sectionHeader(_ section: CueFolderSection) -> some View {
        HStack {
            Text(section.title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.34))
            Spacer()
            if section == .project, !recentProjects.isEmpty {
                Menu {
                    Button("New Folder") { startNewFolder(section) }
                    Section("Link a recent project") {
                        ForEach(recentProjects, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                addLinkedFolder(path)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New project folder")
            } else {
                Button { startNewFolder(section) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.nanoPress)
                .help("New \(section == .project ? "project" : "stash") folder")
            }
        }
        .padding(.leading, 8)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }

    private func folderRow(_ folder: CueFolder) -> some View {
        Group {
            if renamingFolderID == folder.id {
                TextField("Folder name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($folderFieldFocused)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        store.renameFolder(folder.id, to: renameText)
                        renamingFolderID = nil
                    }
                    .onExitCommand { renamingFolderID = nil }
            } else {
                scopeRow(.folder(folder.id), name: folder.name, color: folder.color, linked: folder.linkedPath != nil)
                    .contextMenu { folderMenu(folder) }
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: CueFolder) -> some View {
        Button("Rename") {
            renameText = folder.name
            renamingFolderID = folder.id
            focusField()
        }
        Menu("Link to Project") {
            Button("Choose Folder…") {
                CueRecentProjects.chooseDirectory { store.linkFolder(folder.id, to: $0) }
            }
            if !recentProjects.isEmpty {
                Section("Recent projects") {
                    ForEach(recentProjects, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            store.linkFolder(folder.id, to: path)
                        }
                    }
                }
            }
            if folder.linkedPath != nil {
                Divider()
                Button("Unlink") { store.linkFolder(folder.id, to: nil) }
            }
        }
        Menu("Color") {
            ForEach(CueFolder.palette.indices, id: \.self) { index in
                Button(["Blue", "Orange", "Green", "Purple", "Red", "Teal"][index]) {
                    store.setFolderColor(folder.id, index: index)
                }
            }
        }
        Button(folder.section == .project ? "Move to Stash" : "Move to Projects") {
            store.setFolderSection(folder.id, section: folder.section == .project ? .stash : .project)
        }
        Divider()
        Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id) }
    }

    private func scopeRow(_ scope: CueScope, name: String, color: Color?, linked: Bool) -> some View {
        let selected = store.scope == scope
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                store.scope = scope
                store.editingItemID = nil
            }
            store.save()
        } label: {
            HStack(spacing: 8) {
                if let color {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(color)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                }
                Text(name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if linked {
                    Image(systemName: "link")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .help("Linked to a project folder")
                }
                Spacer(minLength: 4)
                let count = store.openCount(in: scope)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color(red: 0.62, green: 0.71, blue: 1.0) : .white.opacity(0.34))
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? CueStyle.accent.opacity(0.2) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nanoPress)
        .onDrop(of: [.text], delegate: CueFolderDropDelegate(scope: scope, store: store, draggingID: $draggingID))
    }

    private func newFolderField(_ section: CueFolderSection) -> some View {
        TextField(section == .project ? "Project name" : "Folder name", text: $newFolderName)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($folderFieldFocused)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .onSubmit {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let folder = store.addFolder(named: name, section: section)
                    store.scope = .folder(folder.id)
                }
                newFolderSection = nil
            }
            .onExitCommand { newFolderSection = nil }
    }

    private func startNewFolder(_ section: CueFolderSection) {
        newFolderName = ""
        newFolderSection = section
        focusField()
    }

    private func addLinkedFolder(_ path: String) {
        let folder = store.addFolder(named: URL(fileURLWithPath: path).lastPathComponent, section: .project, linkedPath: path)
        store.scope = .folder(folder.id)
    }

    private func focusField() {
        NotificationCenter.default.post(name: .nanoIslandWantsKeyboard, object: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            folderFieldFocused = true
        }
    }

    private var recentProjects: [String] {
        let linked = Set(store.folders.compactMap(\.linkedPath))
        return CueRecentProjects.directories(from: viewModel.sessionStore).filter { !linked.contains($0) }
    }

    // MARK: Main

    private var main: some View {
        let open = store.openItems(in: store.scope)
        let done = store.doneItems(in: store.scope)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.36))
                    TextField("Search cues", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !store.searchQuery.isEmpty {
                        Button { store.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.nanoPress)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    viewModel.beginCueCapture()
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(CuePillButtonStyle(prominent: true))
                .keyboardShortcut("n", modifiers: .command)
                .help("New cue (⌘N)")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.title(for: store.scope))
                    .font(.system(size: 14.5, weight: .semibold))
                if let linked = store.folder(store.scope.folderID)?.linkedDisplayPath {
                    Text(linked)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if open.count > 1 {
                    Text("Drag to reorder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 2)

            if open.isEmpty && done.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(open.enumerated()), id: \.element.id) { index, item in
                            row(item, position: index + 1)
                        }
                        if open.isEmpty {
                            Text(store.searchQuery.isEmpty ? "Everything here is done." : "No open cues match.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        if !done.isEmpty {
                            doneHeader(count: done.count)
                            if store.showsDone {
                                // Its own identity: the lazy stack otherwise reused the
                                // row it had drawn in the open list, so a finished cue
                                // still showed an empty circle and "Up next".
                                ForEach(done) { item in
                                    row(item, position: nil).id("done-\(item.id.uuidString)")
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CueStyle.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                    .background(CueStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(Text("Drop to save as a cue").font(.system(size: 12, weight: .semibold)))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.compactMap { url -> Data? in
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
                return NSImage(contentsOf: url).flatMap(CueStore.pngData)
            }
            guard !images.isEmpty else { return false }
            viewModel.beginCueCapture()
            store.draft?.images = images
            return true
        } isTargeted: { dropTargeted = $0 && draggingID == nil }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(CueStyle.accent)
            Text(store.searchQuery.isEmpty ? "Nothing cued up in \(store.title(for: store.scope))" : "No cues match")
                .font(.system(size: 13, weight: .semibold))
            Text(store.searchQuery.isEmpty ? emptyBlurb : "Try a different search.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyBlurb: String {
        let blurb = "Save to-dos, prompts, and screenshots here in the order you'll need them."
        guard let gesture = viewModel.settings.cueCaptureGesture else { return blurb }
        return "\(blurb) \(gesture) from any app to capture."
    }

    private func doneHeader(count: Int) -> some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { store.showsDone.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(store.showsDone ? 90 : 0))
                    Text("\(count) done")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.nanoPress)
            Spacer()
            if store.showsDone {
                Button("Clear") { store.clearCompleted(in: store.scope, undoable: true) }
                    .buttonStyle(.nanoPress)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Delete the finished cues in this folder")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func row(_ item: CueItem, position: Int?) -> some View {
        CueItemRow(
            item: item,
            position: position,
            store: store,
            viewModel: viewModel,
            recentScopes: store.folders
        )
        .onDrag {
            draggingID = item.id
            // Dropped into another app, a cue is its text.
            return NSItemProvider(object: item.text as NSString)
        }
        .onDrop(of: [.text], delegate: CueRowDropDelegate(target: item.id, store: store, draggingID: $draggingID))
    }
}

private struct CueRowDropDelegate: DropDelegate {
    let target: UUID
    let store: CueStore
    @Binding var draggingID: UUID?

    func validateDrop(info _: DropInfo) -> Bool { draggingID != nil }

    func dropEntered(info _: DropInfo) {
        guard let draggingID, draggingID != target else { return }
        withAnimation(.snappy(duration: 0.2)) {
            store.reorder(draggingID, before: target)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private struct CueFolderDropDelegate: DropDelegate {
    let scope: CueScope
    let store: CueStore
    @Binding var draggingID: UUID?

    func validateDrop(info _: DropInfo) -> Bool { draggingID != nil }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        guard let draggingID else { return false }
        withAnimation(.snappy(duration: 0.2)) {
            store.move(draggingID, to: scope)
        }
        store.showToast("Moved to \(store.title(for: scope))")
        self.draggingID = nil
        return true
    }
}

// MARK: - Row

private struct CueItemRow: View {
    let item: CueItem
    let position: Int?
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel
    let recentScopes: [CueFolder]

    @State private var hovering = false
    @State private var editText = ""
    @State private var focusToken = 0
    /// An edit that was started and neither saved nor cancelled yet.
    @State private var hasPendingEdit = false

    private var isEditing: Bool { store.editingItemID == item.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering && !item.isDone ? 0.3 : 0))
                .frame(width: 10)
                .padding(.top, 4)

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    store.setDone(item.id, !item.isDone, announce: true)
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.isDone ? CueStyle.accent : .white.opacity(hovering ? 0.5 : 0.28), lineWidth: 1.5)
                        .background(Circle().fill(item.isDone ? CueStyle.accent : .clear))
                    if item.isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                }
                .frame(width: 17, height: 17)
                .contentShape(Circle())
            }
            .buttonStyle(.nanoPress)
            .padding(.top, 1)
            .help(item.isDone ? "Mark not done" : "Mark done")
            .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 5) {
                if isEditing {
                    editor
                } else {
                    content
                }
                if !item.images.isEmpty {
                    images
                }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering || isEditing ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { menuItems }
        .onTapGesture(count: 2) { startEditing() }
        .onChange(of: store.editingItemID) { old, new in
            if old == item.id, new != item.id { keepPendingEdit() }
        }
        .onDisappear { keepPendingEdit() }
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .prompt, !item.text.isEmpty {
            Text(item.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(item.isDone ? 0.35 : 0.88))
                .strikethrough(item.isDone, color: .white.opacity(0.35))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if !item.text.isEmpty {
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(item.isDone ? 0.35 : 0.95))
                .strikethrough(item.isDone, color: .white.opacity(0.35))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var editor: some View {
        CueTextView(
            text: $editText,
            fontSize: item.kind == .prompt ? 12 : 12.5,
            monospaced: item.kind == .prompt,
            focusToken: focusToken,
            onSubmit: { _ in commitEdit() },
            onCancel: {
                hasPendingEdit = false
                store.editingItemID = nil
            },
            onImages: nil
        )
        .frame(minHeight: 44, maxHeight: 140)
        .padding(6)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CueStyle.accent.opacity(0.55), lineWidth: 1)
        }
    }

    private var images: some View {
        HStack(spacing: 6) {
            ForEach(item.images, id: \.self) { name in
                if let image = store.image(named: name) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 128, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 0.75)
                        }
                        .opacity(item.isDone ? 0.5 : 1)
                        .onTapGesture { NSWorkspace.shared.open(store.imageURL(named: name)) }
                        .help("Open image")
                        .contextMenu {
                            Button("Copy Image") { store.copyImage(name) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([store.imageURL(named: name)])
                            }
                            Divider()
                            Button("Remove Image", role: .destructive) { store.removeImage(name, from: item.id) }
                        }
                }
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 7) {
            if let position, position == 1, !item.isDone {
                Text("Up next")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.62, green: 0.71, blue: 1.0))
            }
            Menu {
                kindButtons
                sendMenu
            } label: {
                Text(item.kind.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(CueStyle.tint(for: item.kind))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(CueStyle.tint(for: item.kind).opacity(0.13), in: Capsule())
                    .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change what kind of cue this is")
            if !item.images.isEmpty {
                Label("\(item.images.count)", systemImage: "photo")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(metaLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(1)
            Spacer(minLength: 8)
            // Always laid out, so hovering never moves the text above.
            actions
                .opacity(hovering && !isEditing ? 1 : 0)
                .allowsHitTesting(hovering && !isEditing)
                .layoutPriority(1)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var kindButtons: some View {
        ForEach(CueKind.allCases) { kind in
            Button {
                store.update(item.id, kind: kind)
            } label: {
                if kind == item.kind {
                    Label(kind.title, systemImage: "checkmark")
                } else {
                    Text(kind.title)
                }
            }
        }
    }

    private var metaLine: String {
        if let completed = item.completedAt {
            return "Done \(completed.formatted(.relative(presentation: .named)))"
        }
        let when = item.createdAt.formatted(.relative(presentation: .named))
        return item.sourceApp.map { "From \($0) · \(when)" } ?? when
    }

    private var actions: some View {
        HStack(spacing: 5) {
            if !item.isDone, item.kind == .link, let url = linkURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(CueActionStyle())
            }
            Button("Copy") { store.copy(item.id, markDone: false) }
                .buttonStyle(CueActionStyle(prominent: item.isDone))
                .help("Copy to the clipboard")
            if !item.isDone {
                Button("Copy + done") {
                    withAnimation(.snappy(duration: 0.22)) { store.copy(item.id, markDone: true) }
                }
                .buttonStyle(CueActionStyle(prominent: true))
                .help("Copy and check it off")
            }
            Button("Edit") { startEditing() }
                .buttonStyle(CueActionStyle())
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Copy") { store.copy(item.id, markDone: false) }
        if !item.isDone {
            Button("Copy + done") { store.copy(item.id, markDone: true) }
            Button("Move to Top") { withAnimation(.snappy(duration: 0.2)) { store.moveToTop(item.id) } }
        }
        Button("Edit") { startEditing() }
        Menu("Change to") {
            kindButtons
        }
        Menu("Move to") {
            Button("Inbox") { store.move(item.id, to: .inbox) }
            ForEach(recentScopes) { folder in
                Button(folder.name) { store.move(item.id, to: .folder(folder.id)) }
            }
        }
        sendMenu
        Divider()
        Button("Delete", role: .destructive) {
            withAnimation(.snappy(duration: 0.2)) { store.delete(item.id, undoable: true) }
        }
    }

    /// A one-time copy to a connected app's list. Only shown once an app is connected.
    @ViewBuilder
    private var sendMenu: some View {
        let sync = viewModel.cueSync
        if !sync.connectedDestinations.isEmpty {
            Menu("Send to") {
                ForEach(sync.connectedDestinations) { record in
                    Section(record.name) {
                        ForEach(sync.projects[record.id] ?? []) { project in
                            Button(project.name) { send(to: record, project: project) }
                        }
                    }
                }
            }
        }
    }

    private func send(to record: CueSyncState.Destination, project: RemoteProject) {
        let sync = viewModel.cueSync
        let id = item.id
        Task {
            do {
                try await sync.send(id, to: record.id, projectID: project.id)
                store.showToast("Sent to \(project.name)")
            } catch {
                store.showToast("Couldn't send: \(error.localizedDescription)")
            }
        }
    }

    private var linkURL: URL? {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: text.hasPrefix("http") ? text : "https://\(text)")
    }

    private func startEditing() {
        editText = item.text
        hasPendingEdit = true
        store.editingItemID = item.id
        NotificationCenter.default.post(name: .nanoIslandWantsKeyboard, object: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            focusToken += 1
        }
    }

    private func commitEdit() {
        hasPendingEdit = false
        store.update(item.id, text: editText, kind: item.kind == CueKind.guess(for: item.text) ? CueKind.guess(for: editText) : nil)
        store.editingItemID = nil
    }

    /// Clicking another row or folder ends an edit without Return. What was
    /// typed is kept, unless that would leave the cue empty.
    private func keepPendingEdit() {
        guard hasPendingEdit else { return }
        hasPendingEdit = isEditing
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.text else { return }
        store.update(item.id, text: trimmed, kind: item.kind == CueKind.guess(for: item.text) ? CueKind.guess(for: trimmed) : nil)
    }
}

private struct CueActionStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                prominent ? CueStyle.accent : .white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Text view

/// A plain-text editor where Return saves, Shift-Return breaks a line, and
/// pasted or dropped images become attachments instead of text.
struct CueTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var monospaced = false
    var focusToken: Int
    var onSubmit: (_ keepOpen: Bool) -> Void
    var onCancel: () -> Void
    var onImages: (([Data]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = CueNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = NSColor(CueStyle.accent)
        textView.font = font
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onImages = onImages
        let coordinator = context.coordinator
        textView.onCommandReturn = { coordinator.parent.onSubmit(true) }
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? CueNSTextView else { return }
        textView.onImages = onImages
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if textView.font != font { textView.font = font }
        if context.coordinator.appliedFocusToken != focusToken {
            context.coordinator.appliedFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    private var font: NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CueTextView
        var appliedFocusToken = 0

        init(_ parent: CueTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit(false)
                }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

final class CueNSTextView: NSTextView {
    var onImages: (([Data]) -> Void)?
    var onCommandReturn: (() -> Void)?

    /// Command-Return never reaches `insertNewline`, so catch it here.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode), flags.contains(.command), let onCommandReturn {
            onCommandReturn()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let onImages, let images = attachableImages(from: .general) {
            onImages(images)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onImages, let images = attachableImages(from: sender.draggingPasteboard) {
            onImages(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Image files always attach. A bare image attaches only when there is no
    /// text on the pasteboard, so copying from a web page still pastes text.
    private func attachableImages(from pasteboard: NSPasteboard) -> [Data]? {
        let images = CueStore.imageData(from: pasteboard)
        guard !images.isEmpty else { return nil }
        let isFile = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasText = pasteboard.availableType(from: [.string]) != nil
        return isFile || !hasText ? images : nil
    }
}
