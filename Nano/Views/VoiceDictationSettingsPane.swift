import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceDictationSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var controller: VoiceDictationController

    @StateObject private var hotkeyCapture = VoiceDictationHotkeyCapture()
    @StateObject private var sketchHotkeyCapture = VoiceDictationHotkeyCapture()
    @State private var redoStatus: (id: UUID, message: String)?
    @State private var vocabularyQuery = ""
    @State private var vocabularyFilter: VocabularyFilter = .all
    @State private var showsDeveloperExamples = false
    @State private var engineDetails: Set<VoiceDictationEngine> = []
    @State private var screenRecordingAllowed = VoiceDictationSketchSession.hasScreenRecordingAccess
    @State private var editingEntry: VoiceDictationVocabularyEntry?
    @State private var isAddingEntry = false
    @State private var isImportingList = false
    @AppStorage("voiceDictation.historyExpanded") private var isHistoryExpanded = false
    /// Nil until toggled: open while the chosen engine still needs downloading.
    @State private var engineExpandedChoice: Bool?
    @State private var tab: VoiceDictationTab?
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEnabled: Bool { settings.isEnabled(.voiceDictation) }

    /// Opens on this tab instead of the default, for snapshots.
    var initialTab: VoiceDictationTab?

    /// Insights first; the banner above the tabs points to Setup when
    /// something needs doing.
    private var currentTab: VoiceDictationTab {
        tab ?? initialTab ?? .insights
    }

    var body: some View {
        SettingsPage(
            title: "Quill",
            subtitle: "Hold a shortcut, speak, and it pastes. Everything runs on this Mac.",
            link: ("Looking for a Windows version?", URL(string: "https://github.com/valenxi0/Quill")!),
            trailing: AnyView(masterToggle)
        ) {
            if isEnabled {
                readinessBanner
                tabBar
                switch currentTab {
                case .setup:
                    shortcutSection
                    engineSection
                    launchersSection
                    privacySection
                case .writing:
                    styleSection
                    typingSection
                case .vocabulary:
                    vocabularySection
                    suggestionsSection
                    historySection
                case .sketch:
                    sketchTab
                case .insights:
                    VoiceDictationInsightsTab(stats: controller.stats, settings: settings)
                }
            } else {
                SettingsCard {
                    SettingsGroupTitle(
                        title: "Quill is off",
                        detail: NanoModuleRegistry.descriptor(for: .voiceDictation).description
                    )
                }
            }
        }
        .onAppear { controller.refreshMicrophoneAuthorization() }
        .onDisappear {
            hotkeyCapture.end()
            sketchHotkeyCapture.end()
            controller.resumeHotkey()
        }
        // The recorder lives on the Setup tab. Leaving it any other way must
        // not keep the live shortcut suspended.
        .onChange(of: currentTab) { _, _ in cancelHotkeyCapture() }
        .onChange(of: isEnabled) { _, _ in cancelHotkeyCapture() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelHotkeyCapture()
        }
        .sheet(isPresented: $isAddingEntry) {
            VoiceDictationEntryEditor(entry: nil, apps: appCandidates) { entry in
                settings.voiceDictationVocabulary.append(entry)
            }
        }
        .sheet(isPresented: $isImportingList) {
            VoiceDictationListImporter(existing: settings.voiceDictationVocabulary) { entries in
                settings.voiceDictationVocabulary.append(contentsOf: entries)
            }
        }
        .sheet(item: $editingEntry) { entry in
            VoiceDictationEntryEditor(entry: entry, apps: appCandidates) { updated in
                if let index = settings.voiceDictationVocabulary.firstIndex(where: { $0.id == updated.id }) {
                    settings.voiceDictationVocabulary[index] = updated
                }
            }
        }
    }

    private func cancelHotkeyCapture() {
        guard hotkeyCapture.isCapturing || sketchHotkeyCapture.isCapturing else { return }
        hotkeyCapture.end()
        sketchHotkeyCapture.end()
        controller.resumeHotkey()
    }

    private var appCandidates: [VoiceDictationAppChoice] {
        VoiceDictationAppChoice.candidates(stats: controller.stats, history: controller.history)
    }

    // MARK: Header and tabs

    private var masterToggle: some View {
        Toggle("Quill", isOn: Binding(
            get: { settings.isEnabled(.voiceDictation) },
            set: { enabled in
                withAnimation(.easeOut(duration: 0.16)) {
                    settings.setEnabled(enabled, for: .voiceDictation)
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(VoiceDictationTab.allCases) { item in
                    let selected = item == currentTab
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
                                        .matchedGeometryEffect(id: "voice-tab", in: tabNamespace)
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

    private var readinessTitle: String {
        switch controller.readiness {
        case .ready: "Ready · \(settings.voiceDictationHotkey.displayString)"
        case .missingModels: "\(settings.voiceDictationEngine.title) is not downloaded"
        case .microphoneUndetermined: "Microphone access has not been requested"
        case .microphoneDenied: "Microphone access is off for Nano"
        case .disabled: "Off"
        }
    }

    // MARK: Activation

    // MARK: Engine

    private var isEngineExpanded: Bool {
        engineExpandedChoice ?? !controller.modelStore.isReady(settings.voiceDictationEngine)
    }

    @ViewBuilder
    private var engineList: some View {
        Divider()
            .padding(.top, 9)

        ForEach(Array(VoiceDictationEngine.offered.enumerated()), id: \.element) { index, engine in
            engineRow(engine)
                .padding(.vertical, 10)
            if index < VoiceDictationEngine.offered.count - 1 {
                Divider()
            }
        }

        let languages = settings.voiceDictationEngine.selectableLanguages
        if !languages.isEmpty {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                        .font(.system(size: 13, weight: .medium))
                    Text(settings.voiceDictationEngine.languageNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Language", selection: $settings.voiceDictationLanguage) {
                    Text(automaticLanguageTitle).tag(VoiceDictationLanguage.automatic)
                    Divider()
                    ForEach(languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            .padding(.top, 10)
        }
    }

    private var automaticLanguageTitle: String {
        let engine = settings.voiceDictationEngine
        if engine.detectsLanguage { return "Automatic" }
        let code = engine.recognitionLanguage(for: VoiceDictationLanguage.automatic) ?? "en"
        return "Automatic (\(VoiceDictationLanguage.name(for: code)))"
    }

    private func engineRow(_ engine: VoiceDictationEngine) -> some View {
        let states = engine.requiredModels.map { controller.modelStore.state(of: $0) }
        let isDownloading = states.contains { $0.isDownloading }
        let isReady = controller.modelStore.isReady(engine)
        let hasUpdate = controller.modelStore.hasUpdate(for: engine)
        let hasLocalData = controller.modelStore.hasLocalData(for: engine)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    settings.voiceDictationEngine = engine
                } label: {
                    Image(systemName: settings.voiceDictationEngine == engine
                        ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(settings.voiceDictationEngine == engine ? SettingsChrome.accent : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(engine.title)")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(engine.choiceTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(engine.resourceLabel) · \(Self.bytes(engine.requiredModels.reduce(0) { $0 + VoiceDictationModelManifest.descriptor(for: $1).totalBytes }))")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(engine == .parakeetS1 ? SettingsChrome.accent : .secondary)
                            .background(
                                engine == .parakeetS1
                                    ? SettingsChrome.accent.opacity(0.14)
                                    : Color.secondary.opacity(0.10),
                                in: Capsule()
                            )
                    }
                    Text(engine.title + ". " + engine.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isDownloading {
                        Button(engineDetails.contains(engine) ? "Hide details" : "Details") {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if engineDetails.contains(engine) { engineDetails.remove(engine) } else { engineDetails.insert(engine) }
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                Spacer()
                if isDownloading {
                    Button("Cancel") {
                        engine.requiredModels.forEach { controller.modelStore.cancelDownload($0) }
                    }
                    .controlSize(.small)
                } else if isReady {
                    Button("Remove Engine", role: .destructive) {
                        controller.removeModels(for: engine)
                    }
                    .controlSize(.small)
                    .disabled(controller.phase.isBusy)
                } else {
                    HStack(spacing: 6) {
                        Button(hasUpdate ? "Update" : "Download") {
                            controller.downloadModels(for: engine)
                        }
                        if hasLocalData {
                            Button("Remove Engine", role: .destructive) {
                                controller.removeModels(for: engine)
                            }
                            .disabled(controller.phase.isBusy)
                        }
                    }
                    .controlSize(.small)
                }
            }

            if isDownloading || engineDetails.contains(engine) {
                VStack(alignment: .leading, spacing: 6) {
                    if !isDownloading {
                        Text(engine.languageNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(engine.requiredModels) { model in
                        modelRow(model)
                    }
                    ForEach(engine.optionalModels) { model in
                        modelRow(model, isOptional: true)
                    }
                }
                .padding(.leading, 27)
            }
        }
    }

    // MARK: Cleanup

    private func modelRow(_ id: VoiceDictationModelID, isOptional: Bool = false) -> some View {
        let descriptor = VoiceDictationModelManifest.descriptor(for: id)
        let state = controller.modelStore.state(of: id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(descriptor.title)
                        .font(.system(size: 12, weight: .medium))
                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                    }
                    Text(Self.bytes(descriptor.totalBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(isOptional && !state.isDownloading && state != .downloaded
                    ? descriptor.role + " · " + modelStateText(state, descriptor: descriptor)
                    : modelStateText(state, descriptor: descriptor))
                    .font(.caption2)
                    .foregroundStyle(modelStateColor(state))
                    .lineLimit(2)
            }
            Spacer()
            if isOptional {
                modelActions(id, state: state)
            } else {
                // Required models are fetched and removed with their engine's
                // button; a second Download here did the same thing.
                switch state {
                case .downloading(let fraction, _):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                case .verifying:
                    ProgressView().controlSize(.small)
                default:
                    EmptyView()
                }
            }
            Link(destination: descriptor.sourceURL) {
                Image(systemName: "arrow.up.right.square")
            }
            .help("\(descriptor.license) — \(descriptor.licenseNote)")
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func modelActions(_ id: VoiceDictationModelID, state: VoiceDictationModelState) -> some View {
        switch state {
        case .notDownloaded:
            HStack(spacing: 6) {
                Button("Download") { controller.modelStore.download(id) }
                if controller.modelStore.hasLocalData(id) {
                    Button("Remove", role: .destructive) { controller.removeModel(id) }
                        .disabled(controller.phase.isBusy)
                }
            }
            .controlSize(.small)
        case .updateAvailable:
            HStack(spacing: 6) {
                Button("Update") { controller.modelStore.download(id) }
                Button("Remove", role: .destructive) { controller.removeModel(id) }
                    .disabled(controller.phase.isBusy)
            }
            .controlSize(.small)
        case .downloading(let fraction, _):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 90)
            Button("Cancel") { controller.modelStore.cancelDownload(id) }
                .controlSize(.small)
        case .verifying:
            ProgressView().controlSize(.small)
        case .downloaded:
            Button("Remove") {
                controller.removeModel(id)
            }
            .controlSize(.small)
            .disabled(controller.phase.isBusy)
        case .failed:
            HStack(spacing: 6) {
                Button("Retry") { controller.modelStore.download(id) }
                if controller.modelStore.hasLocalData(id) {
                    Button("Remove", role: .destructive) { controller.removeModel(id) }
                        .disabled(controller.phase.isBusy)
                }
            }
            .controlSize(.small)
        }
    }

    private func modelStateText(_ state: VoiceDictationModelState, descriptor: VoiceDictationModelDescriptor) -> String {
        switch state {
        case .notDownloaded: "Not downloaded · \(descriptor.license) · \(descriptor.runtime)"
        case .updateAvailable: "Update available · \(descriptor.license) · \(descriptor.runtime)"
        case .downloading(let fraction, let received):
            "Downloading \(Self.bytes(received)) of \(Self.bytes(descriptor.totalBytes)) (\(Int(fraction * 100))%)"
        case .verifying: "Verifying checksums…"
        case .downloaded: "Ready · \(descriptor.license) · \(descriptor.runtime)"
        case .failed(let message): message
        }
    }

    private func modelStateColor(_ state: VoiceDictationModelState) -> Color {
        switch state {
        case .failed: .orange
        case .downloaded: .secondary
        default: .secondary
        }
    }

    // MARK: Formatting

    private static let developerExamples: [(said: String, typed: String)] = [
        ("git commit dash m quote fix the build quote", "git commit -m \"fix the build\""),
        ("npm install dash dash save dash dev", "npm install --save-dev"),
        ("cd tilde slash projects", "cd ~/projects"),
    ]

    private func redo(_ entry: VoiceDictationHistoryEntry, as level: VoiceDictationCleanupLevel) {
        redoStatus = (entry.id, "Redoing in \(level.title)…")
        Task {
            do {
                let text = try await controller.redo(entry, as: level)
                redoStatus = (entry.id, "Copied in \(level.title): \(text)")
            } catch let error as VoiceDictationError {
                redoStatus = (entry.id, error.detail)
            } catch {
                redoStatus = (entry.id, error.localizedDescription)
            }
        }
    }

    // MARK: Vocabulary

    // MARK: Status

    /// Shown above the tabs only when something stops Quill from working.
    @ViewBuilder
    private var readinessBanner: some View {
        switch controller.readiness {
        case .missingModels where currentTab == .setup:
            EmptyView()
        case .missingModels:
            SettingsBanner(title: readinessTitle, detail: "Download it in Setup, or pick another engine", action: "Open Setup") {
                tab = .setup
                engineExpandedChoice = true
            }
        case .microphoneUndetermined:
            SettingsBanner(title: "Quill needs the microphone", detail: "macOS asks once", action: "Allow") {
                controller.requestMicrophoneAccess()
            }
        case .microphoneDenied:
            SettingsBanner(title: readinessTitle, detail: "Turn on Nano in Privacy & Security, Microphone", action: "Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .ready, .disabled:
            if let problem = controller.hotkeyProblem {
                SettingsBanner(title: "The shortcut isn't working", detail: problem, action: "Open Setup") { tab = .setup }
            } else if !controller.canPasteAutomatically {
                SettingsBanner(
                    title: "Quill copies but can't paste",
                    detail: "Allow Accessibility so the text lands in the field. Until then, press ⌘V",
                    action: "Allow…"
                ) {
                    controller.requestAutomaticPasteAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: Writing

    private var styleSection: some View {
        let available = settings.voiceDictationEngine.appliesCleanup
        return SettingsSection(
            "Style",
            footer: available
                ? "S1-mini cleans English. If cleanup would drop a “not” or invent a number, Quill keeps your words."
                : "\(settings.voiceDictationEngine.title) writes text as heard. Styles need Parakeet + S1-mini."
        ) {
            SettingsRow("Cleanup", symbol: "wand.and.stars", subtitle: settings.voiceDictationCleanupLevel.shortDetail) {
                Picker("Cleanup", selection: $settings.voiceDictationCleanupLevel) {
                    ForEach(VoiceDictationCleanupLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 128)
            }
            SettingsToggleRow(
                "Spoken lists become lists",
                symbol: "list.number",
                subtitle: "“First…, second…” becomes a numbered list in Polished",
                isOn: $settings.voiceDictationStructuresLists
            )
            .disabled(settings.voiceDictationCleanupLevel != .full)
            ForEach(settings.voiceDictationAppStyles) { style in
                appRow(style.bundleID, title: style.appName, subtitle: "Uses its own style") {
                    Picker("Style in \(style.appName)", selection: Binding(
                        get: { style.level },
                        set: { level in
                            if let index = settings.voiceDictationAppStyles.firstIndex(where: { $0.bundleID == style.bundleID }) {
                                settings.voiceDictationAppStyles[index].level = level
                            }
                        }
                    )) {
                        ForEach(VoiceDictationCleanupLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 128)
                    removeButton("Use the default style in \(style.appName)") {
                        settings.voiceDictationAppStyles.removeAll { $0.bundleID == style.bundleID }
                    }
                }
            }
            SettingsRow("Style for one app", symbol: "app.badge", subtitle: "Such as Casual in Discord. Shell commands are always typed as said") {
                VoiceDictationAppPickerButton(
                    candidates: appCandidates.filter { app in
                        !settings.voiceDictationAppStyles.contains { $0.bundleID == app.bundleID }
                    }
                ) { app in
                    guard let app else { return }
                    settings.voiceDictationAppStyles.append(VoiceDictationAppStyle(bundleID: app.bundleID, appName: app.name, level: .light))
                } label: {
                    Text("Add app…")
                }
                .controlSize(.small)
            }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
    }

    /// A row led by an app's icon instead of a symbol tile.
    private func appRow<Trailing: View>(
        _ bundleID: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 11) {
            VoiceDictationAppIconView(bundleID: bundleID)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }

    private func removeButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    enum VocabularyFilter: String, CaseIterable, Identifiable {
        case all, vocabulary, snippets

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All entries"
            case .vocabulary: "Vocabulary"
            case .snippets: "Snippets"
            }
        }
    }

    private var filteredVocabulary: [VoiceDictationVocabularyEntry] {
        let query = vocabularyQuery.trimmingCharacters(in: .whitespaces)
        return settings.voiceDictationVocabulary.filter { entry in
            switch vocabularyFilter {
            case .all: break
            case .vocabulary: guard entry.kind == .vocabulary else { return false }
            case .snippets: guard entry.kind == .snippet else { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.phrase.localizedCaseInsensitiveContains(query)
                || entry.replacement.localizedCaseInsensitiveContains(query)
                || (entry.appName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var vocabularySection: some View {
        SettingsSection(
            "Vocabulary and snippets",
            trailing: settings.voiceDictationVocabulary.isEmpty ? nil : "\(settings.voiceDictationVocabulary.count)",
            footer: "Vocabulary sets how a word is spelled. A snippet swaps a phrase you say for text you wrote. Double-click an entry to edit it."
        ) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $vocabularyQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Picker("Show", selection: $vocabularyFilter) {
                    ForEach(VocabularyFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Menu("Add") {
                    Button("New entry…") { isAddingEntry = true }
                    Button("Paste a list…") { isImportingList = true }
                    Divider()
                    Button("Import JSON…") { importVocabulary() }
                    Button("Export JSON…") { exportVocabulary() }
                        .disabled(settings.voiceDictationVocabulary.isEmpty)
                }
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            boosterRow

            if settings.voiceDictationVocabulary.isEmpty {
                SettingsRow("No entries yet", symbol: "character.book.closed", subtitle: "Try “cloud code” spelled “Claude Code”, or “my sign off” for a closing line")
            } else if filteredVocabulary.isEmpty {
                SettingsRow("Nothing matches “\(vocabularyQuery)”", symbol: "magnifyingglass")
            } else {
                ForEach(filteredVocabulary) { entry in
                    vocabularyRow(entry)
                }
            }
        }
    }

    private func vocabularyRow(_ entry: VoiceDictationVocabularyEntry) -> some View {
        HStack(spacing: 11) {
            SettingsIconTile(symbol: entry.kind == .vocabulary ? "character.book.closed" : "text.quote")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if entry.kind == .vocabulary, entry.phrase == entry.replacement {
                        Text(entry.replacement)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    } else {
                        Text(entry.phrase)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(entry.replacement.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(vocabularyDetail(entry))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let bundleID = entry.bundleID {
                VoiceDictationAppIconView(bundleID: bundleID)
                    .frame(width: 16, height: 16)
                    .help("Only in \(entry.appName ?? bundleID)")
            }
            Toggle("Use \(entry.phrase)", isOn: Binding(
                get: { entry.isEnabled },
                set: { enabled in
                    if let index = settings.voiceDictationVocabulary.firstIndex(where: { $0.id == entry.id }) {
                        settings.voiceDictationVocabulary[index].isEnabled = enabled
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
            Menu {
                Button("Edit…") { editingEntry = entry }
                Divider()
                Button("Delete", role: .destructive) {
                    settings.voiceDictationVocabulary.removeAll { $0.id == entry.id }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
        .opacity(entry.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingEntry = entry }
    }

    /// The same JSON Quill for Windows reads and writes. Entries scoped to a
    /// Mac app come back for all apps on Windows, and the other way round.
    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Quill vocabulary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings.voiceDictationVocabulary).write(to: url, options: .atomic)
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([VoiceDictationVocabularyEntry].self, from: data)
        else { return }
        let known = Set(settings.voiceDictationVocabulary.map { "\($0.phraseKey)|\($0.bundleID ?? "")" })
        settings.voiceDictationVocabulary += entries
            .filter { $0.isValid && !known.contains("\($0.phraseKey)|\($0.bundleID ?? "")") }
            .map { entry in
                var entry = entry
                entry.id = UUID()
                return entry
            }
    }

    private func vocabularyDetail(_ entry: VoiceDictationVocabularyEntry) -> String {
        var parts = [entry.kind.title]
        if entry.bundleID != nil { parts.append("Only in \(entry.appName ?? "one app")") }
        let hits = controller.stats.hits(for: entry.id)
        if hits > 0 { parts.append("Used \(hits)×") }
        return parts.joined(separator: ", ")
    }

    /// Whether the recognizer hears the dictionary, not just the fixer after it.
    @ViewBuilder
    private var boosterRow: some View {
        let hasTerms = settings.voiceDictationVocabulary.contains { $0.kind == .vocabulary && $0.isEnabled }
        let booster = VoiceDictationModelID.parakeetVocabularyBooster
        let state = controller.modelStore.state(of: booster)
        if hasTerms, settings.voiceDictationEngine == .parakeetS1, !state.isDownloaded {
            SettingsRow(
                "Vocabulary booster",
                symbol: "ear.badge.waveform",
                subtitle: state.isDownloading
                    ? "Downloading…"
                    : "Helps Parakeet hear these words, \(Self.bytes(VoiceDictationModelManifest.descriptor(for: booster).totalBytes))"
            ) {
                if state.isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download") { controller.modelStore.download(booster) }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        let suggestions = controller.correctionSuggestions
        let seen = controller.corrections.corrections.count
        SettingsSection("Learned corrections", footer: "Only the word pairs are kept, on this Mac.") {
            SettingsToggleRow(
                "Learn from my fixes",
                symbol: "pencil.and.list.clipboard",
                subtitle: settings.voiceDictationLearnsCorrections && !controller.canPasteAutomatically
                    ? "Needs Accessibility, like automatic paste"
                    : "Fix or delete the same words twice and Quill learns from it",
                subtitleIsWarning: settings.voiceDictationLearnsCorrections && !controller.canPasteAutomatically,
                isOn: $settings.voiceDictationLearnsCorrections
            )
            SettingsToggleRow(
                "Apply what Quill learns automatically",
                symbol: "wand.and.stars",
                subtitle: settings.voiceDictationAppliesLearnedAutomatically
                    ? "Added without asking. Remove anything below."
                    : "Nano asks on the island, at most once a day",
                isOn: Binding(
                    get: { settings.voiceDictationAppliesLearnedAutomatically },
                    set: { on in
                        settings.voiceDictationAppliesLearnedAutomatically = on
                        controller.applyLearnedIfAutomatic()
                    }
                )
            )
            .disabled(!settings.voiceDictationLearnsCorrections)
            ForEach(suggestions) { correction in
                HStack(spacing: 11) {
                    SettingsIconTile(symbol: correction.kind == .word ? "arrow.triangle.swap" : correction.kind == .leaveOut ? "delete.left" : "arrow.uturn.backward")
                    VStack(alignment: .leading, spacing: 1) {
                        Group {
                            switch correction.kind {
                            case .word:
                                HStack(spacing: 6) {
                                    Text(correction.spoken)
                                        .foregroundStyle(.secondary)
                                        .strikethrough(true, color: .secondary.opacity(0.6))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                    Text(correction.written).fontWeight(.medium)
                                }
                            case .leaveOut:
                                Text("Leave out “\(correction.spoken)”").fontWeight(.medium)
                            case .changeOfMind:
                                Text("“\(correction.spoken)” means a change of mind").fontWeight(.medium)
                            }
                        }
                        .font(.system(size: 13))
                        Text((correction.kind == .word ? "Fixed" : "Deleted") + " \(correction.count)×" + (correction.appName.map { " in \($0)" } ?? ""))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Not now") { controller.dismissCorrection(correction) }
                        .controlSize(.small)
                    if correction.kind == .word, let app = correction.appName {
                        Menu("Remember") {
                            Button("Everywhere") { controller.acceptCorrection(correction) }
                            Button("Only in \(app)") { controller.acceptCorrection(correction, onlyInItsApp: true) }
                        } primaryAction: {
                            controller.acceptCorrection(correction)
                        }
                        .controlSize(.small)
                        .fixedSize()
                    } else {
                        Button("Remember") { controller.acceptCorrection(correction) }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 42)
            }
            ForEach(settings.voiceDictationLeaveOutPhrases, id: \.self) { phrase in
                SettingsRow("Leaves out “\(phrase)”", symbol: "delete.left") {
                    Button("Remove") { settings.voiceDictationLeaveOutPhrases.removeAll { $0 == phrase } }
                        .controlSize(.small)
                }
            }
            ForEach(settings.voiceDictationChangeOfMindCues, id: \.self) { cue in
                SettingsRow(
                    "“\(cue)” means a change of mind",
                    symbol: "arrow.uturn.backward",
                    subtitle: "What you said just before it is dropped when you restate it"
                ) {
                    Button("Remove") { settings.voiceDictationChangeOfMindCues.removeAll { $0 == cue } }
                        .controlSize(.small)
                }
            }
            if seen > 0 {
                SettingsRow("\(seen) correction\(seen == 1 ? "" : "s") seen") {
                    Button("Forget all", role: .destructive) { controller.corrections.clear() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var historySection: some View {
        let entries = controller.history.entries
        return SettingsSection("History", footer: "Audio is never kept.") {
            SettingsToggleRow(
                "Keep transcripts for 24 hours",
                symbol: "clock.arrow.circlepath",
                subtitle: "Shows what Quill heard and pasted, and lets you redo it in another style",
                isOn: $settings.voiceDictationHistoryEnabled
            )
            if settings.voiceDictationHistoryEnabled {
                if entries.isEmpty {
                    SettingsRow("Nothing yet", symbol: "tray", subtitle: "Transcripts show up here after you dictate")
                } else {
                    ForEach(entries.prefix(isHistoryExpanded ? 20 : 3)) { entry in
                        historyRow(entry)
                    }
                    SettingsRow(entries.count > 3 && !isHistoryExpanded ? "\(entries.count - 3) more" : "\(entries.count) kept") {
                        if entries.count > 3 {
                            Button(isHistoryExpanded ? "Show less" : "Show all") {
                                withAnimation(.easeOut(duration: 0.18)) { isHistoryExpanded.toggle() }
                            }
                            .controlSize(.small)
                        }
                        Button("Clear", role: .destructive) { controller.history.clear() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: VoiceDictationHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if let bundleID = entry.bundleID {
                    VoiceDictationAppIconView(bundleID: bundleID)
                } else {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let raw = entry.raw, raw != entry.text {
                    Text("Heard “\(raw)”")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Text(redoStatus?.id == entry.id ? redoStatus!.message : Self.historyDetail(entry))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Copy") { _ = VoiceDictationController.copyToClipboard(entry.text) }
                if entry.raw != nil {
                    Menu("Redo as") {
                        ForEach(VoiceDictationCleanupLevel.allCases) { level in
                            Button(level.title) { redo(entry, as: level) }
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { controller.history.remove(entry) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Sketch tab

    private var sketchTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(footer: "Sketch records your whole display while it runs, including anything private on it. The video and screenshots are deleted after 24 hours. Inspired by Scrawl by Kit Langton.") {
                SettingsToggleRow(
                    "Sketch",
                    symbol: "scribble.variable",
                    subtitle: "Talk while you mark up the screen, then paste the screenshots with your words",
                    isOn: $settings.voiceDictationSketchEnabled
                )
            }

            if settings.voiceDictationSketchEnabled {
                let start = settings.voiceDictationSketchHotkey.displayString
                SettingsSection("How it works") {
                    SettingsRow("Press \(start)", symbol: "1.circle", subtitle: "Nano records the screen and your voice. A bar with the controls sits at the bottom")
                    SettingsRow("Mark it up and talk", symbol: "2.circle", subtitle: "Hold \(settings.voiceDictationSketchDrawKey.symbol) and move the pointer, or click Draw and drag. Clicking around is fine")
                    SettingsRow("Press \(start) again", symbol: "3.circle", subtitle: "Screenshots of each mark, click and screen change paste with what you said at each")
                }

                SettingsSection("Controls") {
                    SettingsRow(
                        "Start and finish",
                        symbol: "record.circle",
                        subtitle: sketchHotkeyCapture.isCapturing ? "Press the new shortcut, or Esc to cancel" : controller.sketchHotkeyProblem,
                        subtitleIsWarning: controller.sketchHotkeyProblem != nil
                    ) {
                        shortcutButton(sketchHotkeyCapture, value: settings.voiceDictationSketchHotkey, defaultValue: .sketchDefault) {
                            settings.voiceDictationSketchHotkey = $0
                        }
                    }
                    SettingsRow("Draw while holding", symbol: "hand.draw") {
                        Picker("Draw while holding", selection: $settings.voiceDictationSketchDrawKey) {
                            ForEach(VoiceDictationSketchDrawKey.allCases) { key in
                                Text(key.title).tag(key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 128)
                    }
                    SettingsRow("Undo the last mark", symbol: "arrow.uturn.backward") { keycap("⌘Z") }
                    SettingsRow("Cancel", symbol: "xmark.circle") { keycap("Esc twice") }
                }

                SettingsSection("Permission") {
                    SettingsRow(
                        "Screen Recording",
                        symbol: "rectangle.dashed.badge.record",
                        subtitle: screenRecordingAllowed ? "Allowed. Nano's own windows are left out" : "Needed to record the screen",
                        subtitleIsWarning: !screenRecordingAllowed
                    ) {
                        if screenRecordingAllowed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow…") {
                                VoiceDictationSketchSession.requestScreenRecordingAccess()
                                VoiceDictationSketchSession.openScreenRecordingSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    screenRecordingAllowed = VoiceDictationSketchSession.hasScreenRecordingAccess
                }

                SettingsSection("What gets pasted", footer: "One image with every screenshot, then this text. The video and full-size screenshots are kept for 24 hours.") {
                    Text("""
                    [Sketch 0:42 · video and screenshots in ~/Library/Caches/Nano/Sketches/…]
                    - #1 (0:03) “This button is misaligned.”
                    - #2 (0:09) [clicked] “Now the menu opens under it.”
                    - #3 (0:15) “[1] This header [2] and this one should be bold.”
                    """)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: Setup

    /// A button that records a new shortcut, with Reset beside it once changed.
    @ViewBuilder
    private func shortcutButton(
        _ capture: VoiceDictationHotkeyCapture,
        value: VoiceDictationHotkey,
        defaultValue: VoiceDictationHotkey,
        set: @escaping (VoiceDictationHotkey) -> Void
    ) -> some View {
        if value != defaultValue, !capture.isCapturing {
            Button("Reset") { set(defaultValue) }
                .controlSize(.small)
        }
        Button {
            if capture.isCapturing {
                capture.end()
                controller.resumeHotkey()
            } else {
                cancelHotkeyCapture()
                controller.suspendHotkey()
                capture.begin { hotkey in
                    if let hotkey { set(hotkey) }
                    controller.resumeHotkey()
                }
            }
        } label: {
            Text(capture.isCapturing ? "Recording…" : value.displayString)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 64)
        }
        .controlSize(.small)
    }

    private var shortcutSection: some View {
        SettingsSection("Shortcut", footer: "Press Esc twice within a second to cancel.") {
            SettingsRow(
                "Dictate",
                symbol: "mic",
                subtitle: hotkeyCapture.isCapturing
                    ? "Press the new shortcut. It needs ⌃, ⌥ or ⌘"
                    : VoiceDictationHotkey.isCommonSystemShortcut(settings.voiceDictationHotkey)
                        ? "Replaces \(settings.voiceDictationHotkey.displayString) in every app while Quill is on"
                        : "Works in every app",
                subtitleIsWarning: VoiceDictationHotkey.isCommonSystemShortcut(settings.voiceDictationHotkey)
            ) {
                shortcutButton(hotkeyCapture, value: settings.voiceDictationHotkey, defaultValue: .default) {
                    settings.voiceDictationHotkey = $0
                }
            }
            SettingsRow("Mode", symbol: "hand.tap", subtitle: settings.voiceDictationActivationMode.detail) {
                Picker("Mode", selection: $settings.voiceDictationActivationMode) {
                    ForEach(VoiceDictationActivationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 128)
            }
            SettingsToggleRow(
                "Live preview",
                symbol: "captions.bubble",
                subtitle: "Shows the words under the island as you speak",
                isOn: $settings.voiceDictationLivePreview
            )
        }
    }

    private var engineSection: some View {
        SettingsSection("Engine", footer: "Nothing downloads until you ask. Every file is checked against a pinned checksum.") {
            SettingsRow(settings.voiceDictationEngine.title, symbol: "waveform", subtitle: engineStatus) {
                if controller.readiness == .ready, controller.loadedEngine != settings.voiceDictationEngine, !controller.isLoadingEngine {
                    Button("Load now") { controller.warmEngineIfNeeded() }
                        .controlSize(.small)
                        .help("Load it now so the first dictation starts warm")
                }
                if controller.isLoadingEngine {
                    ProgressView().controlSize(.small)
                }
                Button(isEngineExpanded ? "Done" : "Change…") {
                    withAnimation(.easeOut(duration: 0.18)) { engineExpandedChoice = !isEngineExpanded }
                }
                .controlSize(.small)
            }
            if let error = controller.modelManagementError {
                SettingsRow(error, symbol: "exclamationmark.triangle", subtitleIsWarning: true)
            }
            if isEngineExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    engineList
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var engineStatus: String {
        let engine = settings.voiceDictationEngine
        if engine.requiredModels.contains(where: { controller.modelStore.state(of: $0).isDownloading }) { return "Downloading" }
        guard controller.modelStore.isReady(engine) else { return "Not downloaded" }
        if controller.modelStore.hasUpdate(for: engine) { return "Update available" }
        if controller.isLoadingEngine { return "Loading. The first load can take a while" }
        return controller.loadedEngine == engine ? "Ready and loaded" : "Ready"
    }

    private var typingSection: some View {
        SettingsSection("Typing into apps") {
            SettingsRow(
                "Adapt to the app",
                symbol: "macwindow",
                subtitle: "Agent prompts cleaned, shell commands as typed, no full stop in chat, mail greetings on their own line"
            ) {
                Button(showsDeveloperExamples ? "Hide examples" : "Examples") {
                    withAnimation(.easeOut(duration: 0.18)) { showsDeveloperExamples.toggle() }
                }
                .controlSize(.small)
                Toggle("Adapt to the app", isOn: $settings.voiceDictationAdaptsToApp)
                    .labelsHidden()
                    .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
            }
            if showsDeveloperExamples {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.developerExamples, id: \.said) { example in
                        HStack(spacing: 8) {
                            Text("“\(example.said)”").foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(example.typed).font(.system(size: 11.5, design: .monospaced))
                        }
                        .font(.system(size: 11.5))
                    }
                }
                .padding(.vertical, 10)
                .padding(.leading, 47)
                .padding(.trailing, 12)
            }
            SettingsToggleRow("Match the text around the cursor", symbol: "character.cursor.ibeam",
                              subtitle: "Starts lowercase mid-sentence and adds a missing space",
                              isOn: $settings.voiceDictationFitsToCursor)
            SettingsToggleRow("Numbers as figures", symbol: "number",
                              subtitle: "“Twenty five dollars” becomes “$25”",
                              isOn: $settings.voiceDictationWritesNumbers)
                .disabled(!VoiceDictationNumberFormatter.isAvailable)
            SettingsToggleRow("Line breaks and emoji by voice", symbol: "return",
                              subtitle: "Say “new line”, “new paragraph” or “thumbs up emoji”",
                              isOn: $settings.voiceDictationLayoutCues)
            SettingsToggleRow("Press enter by voice", symbol: "paperplane",
                              subtitle: "End with “press enter” to send after the paste",
                              isOn: $settings.voiceDictationSpokenEnter)
        }
    }

    private var launchersSection: some View {
        SettingsSection("Links and Shortcuts", footer: "Raycast, Alfred, Stream Deck and the Shortcuts app can open these links.") {
            SettingsToggleRow(
                "Let links start the microphone",
                symbol: "link",
                subtitle: "Off, so a web page can't start recording. Stop and cancel always work",
                isOn: Binding(get: { controller.remoteLinksAllowed }, set: { controller.remoteLinksAllowed = $0 })
            )
            SettingsRow("Copy a link", symbol: "doc.on.doc", subtitle: "nano://quill/start, stop, toggle, cancel, sketch, paste-last") {
                Menu("Copy") {
                    ForEach(VoiceDictationController.RemoteCommand.allCases, id: \.self) { command in
                        Button("nano://quill/\(command.rawValue)") {
                            _ = VoiceDictationController.copyToClipboard("nano://quill/\(command.rawValue)")
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var privacySection: some View {
        SettingsSection("Privacy") {
            SettingsRow("Audio stays in memory", symbol: "waveform.slash", subtitle: "Discarded as soon as the text is ready")
            SettingsRow("Nothing leaves this Mac", symbol: "lock.shield", subtitle: "Recognition and cleanup run locally")
            SettingsRow(
                controller.canPasteAutomatically ? "Pastes into the focused field" : "Copies only",
                symbol: "doc.on.clipboard",
                subtitle: controller.canPasteAutomatically ? "Uses Accessibility" : "Allow Accessibility in General to paste too",
                subtitleIsWarning: !controller.canPasteAutomatically
            )
        }
    }

    private static func historyDetail(_ entry: VoiceDictationHistoryEntry) -> String {
        var parts = [entry.createdAt.formatted(date: .omitted, time: .shortened)]
        if let app = entry.appName { parts.append(app) }
        if let seconds = entry.audioSeconds { parts.append(String(format: "%.0f s spoken", seconds.rounded(.up))) }
        if let latency = entry.latency { parts.append(String(format: "ready in %.2f s", latency)) }
        parts.append(entry.engine.title)
        return parts.joined(separator: " · ")
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Add/edit sheet for one vocabulary entry or snippet, with a live test
/// against the exact matcher the controller uses.
private struct VoiceDictationEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let original: VoiceDictationVocabularyEntry?
    let apps: [VoiceDictationAppChoice]
    let onSave: (VoiceDictationVocabularyEntry) -> Void

    @State private var kind: VoiceDictationVocabularyEntry.Kind
    @State private var phrase: String
    @State private var replacement: String
    @State private var sample: String
    @State private var app: VoiceDictationAppChoice?

    init(
        entry: VoiceDictationVocabularyEntry?,
        apps: [VoiceDictationAppChoice],
        onSave: @escaping (VoiceDictationVocabularyEntry) -> Void
    ) {
        original = entry
        self.apps = apps
        self.onSave = onSave
        _app = State(initialValue: entry?.bundleID.map {
            VoiceDictationAppChoice(bundleID: $0, name: entry?.appName ?? $0)
        })
        _kind = State(initialValue: entry?.kind ?? .vocabulary)
        // A plain term is stored with the same phrase and replacement; its
        // "also heard as" field starts empty.
        _phrase = State(initialValue: entry.map { $0.kind == .vocabulary && $0.phrase == $0.replacement ? "" : $0.phrase } ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _sample = State(initialValue: entry.map { "So I said \($0.phrase) yesterday." } ?? "")
    }

    private var draft: VoiceDictationVocabularyEntry {
        VoiceDictationVocabularyEntry(
            id: original?.id ?? UUID(),
            phrase: kind == .vocabulary && phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                : phrase.trimmingCharacters(in: .whitespacesAndNewlines),
            replacement: kind == .vocabulary ? replacement.trimmingCharacters(in: .whitespacesAndNewlines) : replacement,
            kind: kind,
            isEnabled: original?.isEnabled ?? true,
            bundleID: app?.bundleID,
            appName: app?.name
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New entry" : "Edit entry")
                .font(.system(size: 17, weight: .semibold))

            Picker("Kind", selection: $kind) {
                ForEach(VoiceDictationVocabularyEntry.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(kind == .vocabulary
                ? "A name or word Quill should hear and spell your way. Add what it mishears it as, if you know."
                : "When you say the trigger phrase, Quill types the snippet text instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if kind == .vocabulary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Term")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Kubernetes", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also heard as (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("cube or nettys", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trigger phrase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("my sign off", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snippet text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $replacement)
                        .font(.system(size: 12))
                        .frame(height: 72)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        }
                }
            }

            HStack {
                Text("Applies in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VoiceDictationAppPickerButton(candidates: apps, allAppsTitle: "All apps") { picked in
                    app = picked
                } label: {
                    HStack(spacing: 5) {
                        if let app {
                            VoiceDictationAppIconView(bundleID: app.bundleID)
                                .frame(width: 13, height: 13)
                        }
                        Text(app?.name ?? "All apps")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                Spacer()
            }
            if app != nil {
                Text("An entry for one app overrides an all-apps entry with the same phrase there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Test")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Type a sentence as the recognizer might hear it", text: $sample)
                    .textFieldStyle(.roundedBorder)
                Text(testOutput)
                    .font(.system(size: 12))
                    .foregroundStyle(testMatched ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var testOutput: String {
        guard draft.isValid else { return "Fill in both fields to test." }
        guard !sample.isEmpty else { return "Type a test sentence above." }
        let result = VoiceDictationController.preview(entry: draft, sample: sample)
        return result == sample ? "No match in that sentence." : result
    }

    private var testMatched: Bool {
        draft.isValid && !sample.isEmpty
            && VoiceDictationController.preview(entry: draft, sample: sample) != sample
    }
}

/// Paste many names and terms at once. Previews exactly what will be added.
private struct VoiceDictationListImporter: View {
    @Environment(\.dismiss) private var dismiss

    let existing: [VoiceDictationVocabularyEntry]
    let onImport: ([VoiceDictationVocabularyEntry]) -> Void

    @State private var text = ""

    private var parsed: [VoiceDictationVocabularyEntry] {
        VoiceDictationVocabularyImport.parse(text, existing: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a list")
                .font(.system(size: 17, weight: .semibold))
            Text("One term per line or separated by commas. Write “spoken → written” to change how a phrase comes out, like “cloud code → Claude Code”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(height: 160)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            let entries = parsed
            if !entries.isEmpty {
                Text(entries.prefix(6).map { $0.phrase == $0.replacement ? $0.phrase : "\($0.phrase) → \($0.replacement)" }
                    .joined(separator: " · ") + (entries.count > 6 ? " · …" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entries.isEmpty ? "Add" : "Add \(entries.count)") {
                    onImport(entries)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Insights

enum VoiceDictationTab: String, CaseIterable, Identifiable {
    case insights
    case setup
    case writing
    case vocabulary
    case sketch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: "Setup"
        case .writing: "Writing"
        case .vocabulary: "Vocabulary"
        case .sketch: "Sketch"
        case .insights: "Insights"
        }
    }
}

/// One headline number with a label and a line of context.
private struct VoiceStatCard<Extra: View>: View {
    let label: String
    let value: String
    var unit: String?
    let detail: String
    var isHero = false
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: isHero ? 36 : 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            extra
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if isHero {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [SettingsChrome.accent.opacity(0.22), SettingsChrome.accent.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
        }
        .settingsGroupBackground()
        .accessibilityElement(children: .combine)
    }
}

extension VoiceStatCard where Extra == EmptyView {
    init(label: String, value: String, unit: String? = nil, detail: String, isHero: Bool = false) {
        self.init(label: label, value: value, unit: unit, detail: detail, isHero: isHero) { EmptyView() }
    }
}

private enum VoiceFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func compact(_ value: Int) -> String {
        value >= 10_000
            ? String(format: "%.1fk", Double(value) / 1000)
            : value.formatted()
    }

    /// Today and the six days before it.
    static var lastSevenDays: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    static var startOfMonth: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }
}

struct VoiceDictationInsightsTab: View {
    @ObservedObject var stats: VoiceDictationStatsStore
    @ObservedObject var settings: NanoSettings
    @State private var confirmsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stats.isEmpty {
                empty
            } else {
                weekLine
                HStack(alignment: .top, spacing: 8) {
                    speedCard
                    VoiceStatCard(
                        label: "Time saved",
                        value: VoiceFormat.duration(stats.timeSaved(from: VoiceFormat.startOfMonth)),
                        detail: "This month, against \(Int(VoiceDictationStatsStore.typingWordsPerMinute)) wpm typing"
                    )
                    VoiceStatCard(
                        label: "Words dictated",
                        value: stats.totalWords.formatted(),
                        detail: stats.stats.since.map { "Since \($0.formatted(.dateTime.month(.wide).day()))" } ?? ""
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    appsCard
                    streakCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .confirmationDialog("Reset voice insights?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { stats.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Totals, streaks, and app counts are cleared. Your dictionary and settings stay.")
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundStyle(SettingsChrome.accent)
            Text("Insights start with your first dictation")
                .font(.system(size: 14, weight: .semibold))
            Text("Hold \(settings.voiceDictationHotkey.displayString) and speak. Nano counts words and time, never the words themselves.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .settingsGroupBackground()
    }

    @ViewBuilder
    private var weekLine: some View {
        let words = stats.words(from: VoiceFormat.lastSevenDays)
        if words > 0 {
            (Text("In the last 7 days you spoke ")
                + Text("\(words.formatted()) words").foregroundColor(SettingsChrome.accent)
                + Text(" and saved ")
                + Text(VoiceFormat.duration(stats.timeSaved(from: VoiceFormat.lastSevenDays))).foregroundColor(SettingsChrome.accent)
                + Text(" of typing."))
                .font(.system(size: 15, weight: .semibold))
        } else {
            Text("Nothing dictated in the last 7 days.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var speedCard: some View {
        let speed = stats.speed()
        VoiceStatCard(
            label: "Speaking speed",
            value: speed.map { "\(Int($0.rounded()))" } ?? "--",
            unit: "wpm",
            detail: speed.map {
                String(format: "%.1fx your typing speed", $0 / VoiceDictationStatsStore.typingWordsPerMinute)
            } ?? "Needs a few more dictations",
            isHero: true
        ) {
            let points = stats.dailySpeeds()
            if points.count >= 2 {
                Sparkline(values: points)
                    .frame(height: 24)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var appsCard: some View {
        let apps = Array(stats.apps().prefix(5))
        let top = max(apps.first?.words ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Where you dictate").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("This month").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if apps.isEmpty {
                Text("Nothing yet this month.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    AppIcon(bundleID: app.bundleID)
                        .frame(width: 16, height: 16)
                    Text(app.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(width: 92, alignment: .leading)
                    GeometryReader { proxy in
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(SettingsChrome.accent)
                            .frame(width: max(proxy.size.width * CGFloat(app.words) / CGFloat(top), 3), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    Text(VoiceFormat.compact(app.words))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(app.name), \(app.words) words")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsGroupBackground()
    }

    private var streakCard: some View {
        let weeks = stats.heatmap(weeks: 15)
        let peak = max(weeks.flatMap { $0 }.compactMap { $0?.words }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(stats.currentStreak == 1 ? "1 day streak" : "\(stats.currentStreak) day streak")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Longest \(stats.longestStreak)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { index in
                            if let day = week[index] {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Self.shade(day.words, peak: peak))
                                    .frame(width: 11, height: 11)
                                    .overlay {
                                        if Calendar.current.isDateInToday(day.date) {
                                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                                .strokeBorder(Color.primary, lineWidth: 1.2)
                                        }
                                    }
                                    .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).month().day())): \(day.words.formatted()) words")
                            } else {
                                Color.clear.frame(width: 11, height: 11)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictation activity over the last 15 weeks")
            HStack(spacing: 4) {
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Self.shade(level == 0 ? 0 : level * peak / 4, peak: peak))
                        .frame(width: 10, height: 10)
                }
                Text("More")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsGroupBackground()
    }

    /// One hue, stepped by share of the busiest day.
    private static func shade(_ words: Int, peak: Int) -> Color {
        guard words > 0 else { return Color.primary.opacity(0.07) }
        let share = Double(words) / Double(peak)
        let opacity = share > 0.75 ? 1 : share > 0.5 ? 0.75 : share > 0.25 ? 0.5 : 0.3
        return SettingsChrome.accent.opacity(opacity)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text("Insights keep counts only: words, seconds, and the app you dictated into. Never your words. Stored on this Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle("Keep insights", isOn: $settings.voiceDictationInsightsEnabled)
                .toggleStyle(HeroSwitchToggleStyle())
                .font(.system(size: 12))
                .fixedSize()
            Button("Reset…") { confirmsReset = true }
                .controlSize(.small)
                .disabled(stats.isEmpty)
        }
        .padding(.top, 4)
    }
}
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let low = (values.min() ?? 0) * 0.95
            let high = max((values.max() ?? 1) * 1.02, low + 1)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                    y: proxy.size.height * (1 - CGFloat((value - low) / (high - low)))
                )
            }
            ZStack(alignment: .topLeading) {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(SettingsChrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .position(last)
                }
            }
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }
}
