import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CueSettingsTab: String, CaseIterable, Identifiable {
    case overview
    case folders
    case capture
    case sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .folders: "Folders"
        case .capture: "Capture"
        case .sync: "Sync"
        }
    }
}

struct CueSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel
    @State private var tab: CueSettingsTab

    init(settings: NanoSettings, store: CueStore, viewModel: IslandViewModel, initialTab: CueSettingsTab = .overview) {
        self.settings = settings
        self.store = store
        self.viewModel = viewModel
        _tab = State(initialValue: initialTab)
    }
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPage(
            title: "Cue",
            symbol: "checklist",
            subtitle: "To-dos, prompts, and screenshots per project. Stays on this Mac unless you set up Sync.",
            trailing: AnyView(
                Toggle("Cue", isOn: Binding(
                    get: { settings.isEnabled(.cue) },
                    set: { enabled in
                        withAnimation(.easeOut(duration: 0.16)) { settings.setEnabled(enabled, for: .cue) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
            )
        ) {
            if settings.isEnabled(.cue) {
                tabBar
                switch tab {
                case .overview:
                    CueOverviewTab(settings: settings, store: store)
                case .folders:
                    CueFoldersTab(store: store, viewModel: viewModel)
                case .capture:
                    CueCaptureTab(settings: settings, store: store, viewModel: viewModel)
                case .sync:
                    CueSyncSettingsTab(sync: viewModel.cueSync, store: store)
                }
            } else {
                SettingsCard {
                    SettingsGroupTitle(
                        title: "Cue is off",
                        detail: NanoModuleRegistry.descriptor(for: .cue).description
                    )
                }
            }
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(CueSettingsTab.allCases) { item in
                    let selected = item == tab
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { tab = item }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.bottom, 8)
                            .overlay(alignment: .bottom) {
                                if selected {
                                    Capsule()
                                        .fill(SettingsChrome.accent)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "cue-tab", in: tabNamespace)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
                Spacer()
            }
            Divider()
        }
    }
}

// MARK: - Overview

private struct CueOverviewTab: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var store: CueStore

    private var open: [CueItem] { store.items.filter { !$0.isDone } }

    private var startOfWeek: Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    private var startOfMonth: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.items.isEmpty {
                empty
            } else {
                headline
                projectsCard
                HStack(alignment: .top, spacing: 8) {
                    capturedCard
                    kindsCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text("Worked out from your cues on this Mac. Nothing is uploaded.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 26))
                .foregroundStyle(SettingsChrome.accent)
            Text("No cues yet")
                .font(.system(size: 14, weight: .semibold))
            Text(settings.cueCaptureGesture.map { "\($0) in any app to save a to-do, prompt, or screenshot. This page fills in as you go." }
                ?? "Save a to-do, prompt, or screenshot from the island. This page fills in as you go.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .settingsGroupBackground()
    }

    private var headline: some View {
        let projectCount = Set(open.map(\.folderID)).count
        let finished = store.items.filter { ($0.completedAt ?? .distantPast) >= startOfWeek }.count
        return (Text("\(open.count) open").foregroundColor(SettingsChrome.accent)
            + Text(" across \(projectCount) \(projectCount == 1 ? "place" : "places"). You finished ")
            + Text("\(finished)").foregroundColor(SettingsChrome.accent)
            + Text(" this week."))
            .font(.system(size: 15, weight: .semibold))
    }

    private var projectsCard: some View {
        let rows: [(name: String, color: Color, open: Int)] = store.folders.map {
            ($0.name, $0.color, store.openCount(in: .folder($0.id)))
        } + [("Inbox", Color.secondary, store.openCount(in: .inbox))]
        let top = max(rows.map(\.open).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Open by folder").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Right now").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 8, height: 8)
                    Text(row.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(width: 128, alignment: .leading)
                    GeometryReader { proxy in
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(SettingsChrome.accent)
                            .frame(width: row.open == 0 ? 0 : max(proxy.size.width * CGFloat(row.open) / CGFloat(top), 3), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    Text("\(row.open) open")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(13)
        .settingsGroupBackground()
    }

    private var capturedCard: some View {
        let month = store.items.filter { $0.createdAt >= startOfMonth }
        let sources = Dictionary(grouping: month.compactMap(\.sourceApp), by: { $0 })
            .sorted { $0.value.count > $1.value.count }
            .prefix(2)
            .map(\.key)
        let detail = sources.isEmpty
            ? "This month"
            : "This month, mostly from " + sources.joined(separator: " and ")
        return stat("Captured", value: month.count.formatted(), detail: detail)
    }

    private var kindsCard: some View {
        let total = max(store.items.count, 1)
        let shares = CueKind.allCases.map { kind in
            (kind, store.items.filter { $0.kind == kind }.count)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("What you save")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                        if share.1 > 0 {
                            Rectangle()
                                .fill(Self.shade(index))
                                .frame(width: max((proxy.size.width - 6) * CGFloat(share.1) / CGFloat(total), 2))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .padding(.top, 4)
            FlowLegend(items: shares.filter { $0.1 > 0 }.map { share in
                let index = CueKind.allCases.firstIndex(of: share.0) ?? 0
                return (Self.shade(index), "\(share.0.title)s \(Int((Double(share.1) / Double(total) * 100).rounded()))%")
            })
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsGroupBackground()
    }

    /// One hue, stepped by order, so the kinds read as parts of one whole.
    private static func shade(_ index: Int) -> Color {
        [SettingsChrome.accent, SettingsChrome.accent.opacity(0.62), SettingsChrome.accent.opacity(0.36), Color.primary.opacity(0.2)][index % 4]
    }

    private func stat(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsGroupBackground()
        .accessibilityElement(children: .combine)
    }
}

private struct FlowLegend: View {
    let items: [(Color, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                HStack(spacing: 12) {
                    ForEach(start..<min(start + 2, items.count), id: \.self) { index in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(items[index].0).frame(width: 8, height: 8)
                            Text(items[index].1)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Folders

private struct CueFoldersTab: View {
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel
    @State private var isDropTargeted = false

    private var recentProjects: [String] {
        let linked = Set(store.folders.compactMap(\.linkedPath))
        return CueRecentProjects.directories(from: viewModel.sessionStore).filter { !linked.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let projects = store.folders(in: .project)
            SettingsSection("Projects", trailing: "A linked folder shows its project's path") {
                if projects.isEmpty {
                    SettingsRow("No projects yet", subtitle: "Add one below. Cues go to the Inbox until then.")
                }
                ForEach(projects) { folder in
                    CueFolderRow(folder: folder, store: store, recentProjects: recentProjects)
                }
            }

            dropZone

            let stash = store.folders(in: .stash)
            SettingsSection("Stash", trailing: "Prompts and ideas you reuse, not tied to a project") {
                if stash.isEmpty {
                    SettingsRow("No stash folders", subtitle: "Good for a prompt library or a someday list.")
                }
                ForEach(stash) { folder in
                    CueFolderRow(folder: folder, store: store, recentProjects: recentProjects)
                }
            }
            Button {
                _ = store.addFolder(named: "New Folder", section: .stash)
            } label: {
                Label("New stash folder", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private var dropZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
            Text("Drop a project folder here to link it, or")
            Button("choose…") {
                CueRecentProjects.chooseDirectory { path in
                    _ = store.addFolder(named: URL(fileURLWithPath: path).lastPathComponent, section: .project, linkedPath: path)
                }
            }
            .buttonStyle(.link)
            if !recentProjects.isEmpty {
                Menu("Recent") {
                    ForEach(recentProjects, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            _ = store.addFolder(named: URL(fileURLWithPath: path).lastPathComponent, section: .project, linkedPath: path)
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(12)
        .background(isDropTargeted ? SettingsChrome.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? SettingsChrome.accent : Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.hasDirectoryPath else { return }
                    let path = url.path
                    Task { @MainActor in
                        _ = store.addFolder(named: url.lastPathComponent, section: .project, linkedPath: path)
                    }
                }
            }
            return true
        }
    }
}

private struct CueFolderRow: View {
    let folder: CueFolder
    @ObservedObject var store: CueStore
    let recentProjects: [String]
    @State private var name: String
    @FocusState private var nameFocused: Bool
    @State private var confirmingDelete = false

    init(folder: CueFolder, store: CueStore, recentProjects: [String]) {
        self.folder = folder
        self.store = store
        self.recentProjects = recentProjects
        _name = State(initialValue: folder.name)
    }

    private var linkIsMissing: Bool {
        guard let path = folder.linkedPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        HStack(spacing: 11) {
            // A plain view: menu labels on macOS drop their background.
            Image(systemName: folder.section == .project ? "folder.fill" : "archivebox.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(folder.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }
                    .onChange(of: folder.name) { _, newName in name = newName }
                    .onDisappear { commitName() }
                if folder.section == .project {
                    if linkIsMissing, let shown = folder.linkedDisplayPath {
                        Text("Linked folder not found: \(shown)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else {
                        Text(folder.linkedDisplayPath ?? "Not linked to a project folder")
                            .font(.system(size: 11, design: folder.linkedPath == nil ? .default : .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(counts)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if linkIsMissing || (folder.section == .project && folder.linkedPath == nil) {
                Button(linkIsMissing ? "Relink…" : "Link…") {
                    CueRecentProjects.chooseDirectory { store.linkFolder(folder.id, to: $0) }
                }
                .controlSize(.small)
            }

            Menu {
                if folder.section == .project {
                    Button("Choose Folder…") {
                        CueRecentProjects.chooseDirectory { store.linkFolder(folder.id, to: $0) }
                    }
                    if !recentProjects.isEmpty {
                        Menu("Link to Recent Project") {
                            ForEach(recentProjects, id: \.self) { path in
                                Button(URL(fileURLWithPath: path).lastPathComponent) { store.linkFolder(folder.id, to: path) }
                            }
                        }
                    }
                    if folder.linkedPath != nil {
                        Button("Unlink") { store.linkFolder(folder.id, to: nil) }
                    }
                    Divider()
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
                Button("Move Up") { store.moveFolder(folder.id, by: -1) }
                Button("Move Down") { store.moveFolder(folder.id, by: 1) }
                Divider()
                Button("Delete Folder", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More. Deleting moves its cues to the Inbox.")
            .confirmationDialog(
                "Delete \u{201C}\(folder.name)\u{201D}?",
                isPresented: $confirmingDelete
            ) {
                Button("Delete folder", role: .destructive) { store.deleteFolder(folder.id) }
            } message: {
                Text("Its cues move to the Inbox. The folder's name, color and project link are lost.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }

    /// Saves the typed name once editing ends. An empty field goes back to
    /// the name it had.
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else {
            name = folder.name
            return
        }
        store.renameFolder(folder.id, to: trimmed)
    }

    private var counts: String {
        let open = store.openCount(in: .folder(folder.id))
        if folder.section == .stash {
            return "\(open) saved"
        }
        return "\(open) open, \(store.doneCount(in: .folder(folder.id))) done"
    }
}

// MARK: - Capture

private struct CueCaptureTab: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var store: CueStore
    @ObservedObject var viewModel: IslandViewModel
    @StateObject private var hotkeyCapture = VoiceDictationHotkeyCapture()
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var confirmsClear = false
    @State private var librarySize: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Capture", footer: "After you save, focus goes back to the app you were in.") {
                SettingsRow(
                    "Keyboard shortcut",
                    symbol: "keyboard",
                    subtitle: shortcutDetail,
                    subtitleIsWarning: viewModel.cueQuickCaptureError != nil || shortcutClashes
                ) {
                    if settings.cueQuickCaptureEnabled {
                        if settings.cueQuickCaptureHotkey != .cueQuickCaptureDefault {
                            Button("Reset") { settings.cueQuickCaptureHotkey = .cueQuickCaptureDefault }
                                .controlSize(.small)
                        }
                        Button {
                            if hotkeyCapture.isCapturing {
                                hotkeyCapture.end()
                            } else {
                                hotkeyCapture.begin { hotkey in
                                    if let hotkey { settings.cueQuickCaptureHotkey = hotkey }
                                }
                            }
                        } label: {
                            Text(hotkeyCapture.isCapturing ? "Recording…" : settings.cueQuickCaptureHotkey.displayString)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .frame(minWidth: 64)
                        }
                        .controlSize(.small)
                    }
                    switchFor($settings.cueQuickCaptureEnabled, "Keyboard shortcut")
                }
                SettingsRow(
                    "Start with the selected text",
                    symbol: "textformat",
                    subtitle: accessibilityTrusted ? "Whatever you had selected becomes the cue" : "Needs Accessibility to read the selected text",
                    subtitleIsWarning: !accessibilityTrusted && settings.cuePullsSelection
                ) {
                    if settings.cuePullsSelection, !accessibilityTrusted {
                        Button("Grant") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    switchFor($settings.cuePullsSelection, "Start with the selected text")
                }
            }

            SettingsSection("Island") {
                SettingsRow(
                    "Show open cues on the closed island",
                    symbol: "number.circle",
                    subtitle: "When nothing else is playing or running"
                ) {
                    switchFor($settings.cueShowsCompactCount, "Show open cues on the closed island")
                }
            }

            SettingsSection("Library") {
                SettingsRow(
                    "\(store.totalOpenCount) open, \(store.doneCount) done, \(store.folders.count) folder\(store.folders.count == 1 ? "" : "s")",
                    subtitle: librarySize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " including screenshots" }
                ) {
                    Button("Show in Finder") { store.reveal() }
                        .controlSize(.small)
                    Button("Clear done…") { confirmsClear = true }
                        .controlSize(.small)
                        .disabled(store.doneCount == 0)
                }
                if let error = store.errorMessage {
                    SettingsRow(error, symbol: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear { measureLibrary() }
        .onDisappear { hotkeyCapture.end() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .confirmationDialog(
            "Delete \(store.doneCount) finished \(store.doneCount == 1 ? "cue" : "cues")?",
            isPresented: $confirmsClear
        ) {
            Button("Delete", role: .destructive) {
                store.clearCompleted()
                measureLibrary()
            }
        } message: {
            Text("Their images are deleted too. Open cues aren't touched.")
        }
    }

    private func switchFor(_ binding: Binding<Bool>, _ label: String) -> some View {
        Toggle(label, isOn: binding)
            .labelsHidden()
            .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
    }

    private var shortcutClashes: Bool {
        settings.cueQuickCaptureEnabled && settings.cueQuickCaptureHotkey == settings.voiceDictationHotkey
    }

    private var shortcutDetail: String {
        if hotkeyCapture.isCapturing { return "Press the new shortcut. Esc cancels." }
        if let error = viewModel.cueQuickCaptureError { return error }
        if shortcutClashes { return "Same as the dictation shortcut. Pick a different one so both work." }
        return "Works without Accessibility"
    }

    private func measureLibrary() {
        let url = store.directoryURL
        Task {
            let size = await Task.detached(priority: .utility) { () -> Int64 in
                guard let files = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey]
                ) else { return 0 }
                var total: Int64 = 0
                while let file = files.nextObject() as? URL {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                return total
            }.value
            librarySize = size
        }
    }
}
