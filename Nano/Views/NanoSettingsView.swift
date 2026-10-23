import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case island
    case dashboard
    case notifications
    case agents
    case voiceDictation
    case cue
    case mixer
    case permissions
    case privacy
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .island: "Island"
        case .dashboard: "Dashboard"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .voiceDictation: "Quill"
        case .cue: "Cue"
        case .mixer: "Mixer"
        case .permissions: "Permissions"
        case .privacy: "Privacy & About"
        case .support: "Support Nano"
        }
    }

    /// The animated sidebar glyph where one exists; SF Symbols otherwise.
    var hoverIcon: SettingsHoverIcon? {
        switch self {
        case .general: .slidersHorizontal
        case .dashboard: .layoutDashboard
        case .notifications: .filledBell
        case .agents: .terminal
        case .voiceDictation: .radio
        case .cue: .listCheck
        case .privacy: .shieldCheck
        // Mixer shows its own symbol, so it does not share General's glyph.
        case .island, .permissions, .mixer, .support: nil
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .island: "rectangle.topthird.inset.filled"
        case .dashboard: "square.grid.2x2"
        case .notifications: "bell"
        case .agents: "terminal"
        case .voiceDictation: "waveform"
        case .cue: "checklist"
        case .mixer: "slider.vertical.3"
        case .permissions: "hand.raised"
        case .privacy: "lock.shield"
        case .support: "heart"
        }
    }

    /// Words people search for that don't appear in the page title.
    var keywords: [String] {
        switch self {
        case .general:
            ["click to open", "hover", "display", "monitor", "features", "music", "calendar", "weather", "timer", "camera", "tray", "add-ons", "setup"]
        case .island:
            ["appearance", "surface", "solid black", "liquid glass", "hybrid", "color", "opacity", "shape", "notch", "floating", "gradient", "tint"]
        case .dashboard:
            ["widgets", "layout", "slots", "drag", "customize"]
        case .notifications:
            ["volume", "brightness", "bluetooth", "airpods", "charging", "timer", "imessage", "media keys", "hud"]
        case .agents:
            ["claude", "codex", "cursor", "gemini", "tokens", "usage", "quota", "hooks", "remaining"]
        case .voiceDictation:
            ["quill", "dictation", "voice", "microphone", "shortcut", "transcribe", "model", "language", "dictionary"]
        case .cue:
            ["to-do", "prompt", "capture", "screenshot", "folders"]
        case .mixer:
            ["audio", "volume", "sound", "mute", "output", "headphones", "speaker"]
        case .permissions:
            ["accessibility", "camera", "microphone", "location", "automation", "full disk access", "contacts", "grant"]
        case .privacy:
            ["about", "version", "analytics", "telemetry", "data"]
        case .support:
            ["donate", "tip", "ko-fi", "sponsor", "github", "projects", "repositories"]
        }
    }

    @MainActor
    static func available(settings: NanoSettings) -> [SettingsDestination] {
        allCases.filter { destination in
            switch destination {
            case .agents: settings.isEnabled(.agents)
            case .voiceDictation: settings.isEnabled(.voiceDictation)
            case .cue: settings.isEnabled(.cue)
            case .mixer: settings.isEnabled(.mixer)
            default: true
            }
        }
    }

    /// Pages matching a search, with the keyword that matched when the title didn't.
    @MainActor
    static func search(_ query: String, settings: NanoSettings) -> [(SettingsDestination, String?)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return available(settings: settings).compactMap { destination in
            if destination.title.lowercased().contains(needle) { return (destination, nil) }
            guard let hit = destination.keywords.first(where: { $0.contains(needle) }) else { return nil }
            return (destination, hit.prefix(1).uppercased() + hit.dropFirst())
        }
    }
}

enum SettingsNavGroup: String, CaseIterable, Identifiable {
    case island
    case work
    case nano

    var id: String { rawValue }

    /// Only add-ons get a heading; the other groups are separated by space.
    var title: String? {
        self == .work ? "Add-ons" : nil
    }

    var destinations: [SettingsDestination] {
        switch self {
        case .island: [.general, .island, .dashboard, .notifications]
        case .work: [.agents, .voiceDictation, .cue, .mixer]
        case .nano: [.permissions, .privacy, .support]
        }
    }

    @MainActor
    func visibleDestinations(settings: NanoSettings) -> [SettingsDestination] {
        let available = SettingsDestination.available(settings: settings)
        return destinations.filter { available.contains($0) }
    }

    @MainActor
    static func visible(settings: NanoSettings) -> [SettingsNavGroup] {
        allCases.filter { !$0.visibleDestinations(settings: settings).isEmpty }
    }
}

enum SettingsChrome {
    /// Hard sRGB blue. `Color.accentColor` follows the Mac accent, which is green here.
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 1)
}

enum SettingsMotion {
    static func page(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : NanoMotion.smooth(0.25)
    }

    static func accordion(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : NanoMotion.smooth(0.25)
    }

    /// The new page slides 8 pt in from the right; the old one only fades,
    /// and quickly, so the two never compete. No blur: on a full-height page
    /// it costs an offscreen pass every frame.
    static var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: SettingsPaneTransition(progress: 1),
                identity: SettingsPaneTransition(progress: 0)
            ),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

private struct SettingsPaneTransition: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .offset(x: progress * 8)
    }
}

struct NanoSettingsView: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel

    @StateObject private var permissions: NanoPermissionMonitor
    @State private var destination: SettingsDestination?
    @State private var iconPlayToken: [SettingsDestination: Int] = [:]
    @State private var query = ""
    @State private var searchSelection = 0
    /// The row a search result pointed at; cleared after a moment.
    @State private var highlight: String?
    @Namespace private var tabNamespace

    private static let paneTop = "settings.pane.top"

    // Update the handle and destination together if the creator's profile changes.
    static let creatorHandle = "@valenxi"
    static let creatorURL = URL(string: "https://x.com/valenxi?s=11&t=zI4V0oRLNb5oulf8uLjCBg")

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        settings: NanoSettings,
        viewModel: IslandViewModel,
        initialDestination: SettingsDestination = .general
    ) {
        self.settings = settings
        self.viewModel = viewModel
        _destination = State(initialValue: initialDestination)
        _permissions = StateObject(wrappedValue: NanoPermissionMonitor(viewModel: viewModel))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)

            ScrollViewReader { proxy in
                ScrollView {
                    // A ZStack, so the outgoing and incoming pages overlap
                    // instead of stacking one above the other for a moment.
                    ZStack(alignment: .topLeading) {
                        selectedPane
                            .id(destination ?? .general)
                            .transition(SettingsMotion.pageTransition)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(30)
                    }
                    .id(Self.paneTop)
                    .animation(SettingsMotion.page(reduceMotion), value: destination)
                    // One switch style everywhere. Checkboxes read as a form to fill in.
                    .toggleStyle(HeroSwitchToggleStyle())
                    .environment(\.settingsHighlight, highlight)
                }
                .scrollIndicators(.never)
                // A new page starts at its top, not at the old page's scroll.
                .onChange(of: destination) { _, _ in
                    proxy.scrollTo(Self.paneTop, anchor: .top)
                }
                .task(id: highlight) {
                    guard let target = highlight else { return }
                    // Let the page transition land before scrolling to the row.
                    try? await Task.sleep(for: .milliseconds(320))
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    try? await Task.sleep(for: .seconds(1.6))
                    if highlight == target { highlight = nil }
                }
            }
            .background {
                SettingsContentPaneBackground(
                    reduceTransparency: reduceTransparency,
                    colorScheme: colorScheme
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28), lineWidth: 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 18, y: 8)
            .padding(.top, SettingsWindowChrome.titlebarClearance)
            .padding(.bottom, 12)
            .padding(.trailing, 12)
        }
        .background {
            SettingsWindowSurface(reduceTransparency: reduceTransparency, colorScheme: colorScheme)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .top)
        .modifier(SettingsWindowClearBackground())
        .modifier(NanoPermissionRefresh(monitor: permissions, viewModel: viewModel))
        .tint(SettingsChrome.accent)
        .frame(width: 920, height: 680)
        .onReceive(NotificationCenter.default.publisher(for: .nanoOpenSettings)) { note in
            if let page = (note.object as? String).flatMap(SettingsDestination.init(rawValue:)) {
                select(page)
            }
        }
        .onChange(of: settings.enabledModules) { _, enabledModules in
            let leavingAgents = destination == .agents && !enabledModules.contains(.agents)
            let leavingVoice = destination == .voiceDictation && !enabledModules.contains(.voiceDictation)
            let leavingCue = destination == .cue && !enabledModules.contains(.cue)
            let leavingMixer = destination == .mixer && !enabledModules.contains(.mixer)
            guard leavingAgents || leavingVoice || leavingCue || leavingMixer else { return }
            select(.general, playIcon: false)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: SettingsWindowChrome.titlebarClearance)
                .allowsHitTesting(false)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            ScrollView {
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        navigation
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 12)
                .animation(SettingsMotion.page(reduceMotion), value: destination)
            }
            .scrollIndicators(.never)

            VStack(alignment: .leading, spacing: 10) {
                reportBugButton
                brand
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit {
                    let results = SettingsSearchItem.search(query, settings: settings)
                    if results.indices.contains(searchSelection) {
                        open(results[searchSelection])
                    } else if let page = SettingsDestination.search(query, settings: settings).first {
                        select(page.0)
                        query = ""
                    }
                }
                .onKeyPress(.downArrow) {
                    let count = SettingsSearchItem.search(query, settings: settings).count
                    guard count > 0 else { return .ignored }
                    searchSelection = min(searchSelection + 1, count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    searchSelection = max(searchSelection - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .onChange(of: query) { _, _ in searchSelection = 0 }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SettingsNavGroup.visible(settings: settings)) { group in
                VStack(alignment: .leading, spacing: 1) {
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 3)
                    }
                    ForEach(group.visibleDestinations(settings: settings)) { item in
                        navItem(item)
                    }
                }
            }
        }
    }

    private func navItem(_ item: SettingsDestination) -> some View {
        let selected = destination == item
        let missing = item == .permissions ? permissions.missing.count : 0

        return HStack(spacing: 9) {
            Group {
                if let hoverIcon = item.hoverIcon {
                    SettingsHoverIconView(icon: hoverIcon, playToken: iconPlayToken[item, default: 0], size: 13)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .background(
                selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if missing > 0 {
                Text("\(missing)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Color.orange, in: Capsule())
                    .help("\(missing) permission\(missing == 1 ? "" : "s") not granted")
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(SettingsChrome.accent)
                    .matchedGeometryEffect(id: "settings-tab-pill", in: tabNamespace)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(missing > 0 ? "\(missing) not granted" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(item) }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsSearchItem.search(query, settings: settings)
        let pages = SettingsDestination.search(query, settings: settings)
            .map(\.0)
            .filter { page in !results.contains { $0.destination == page } }
        VStack(alignment: .leading, spacing: 1) {
            if results.isEmpty && pages.isEmpty {
                Text("No settings match “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                if index == 0 || results[index - 1].destination != item.destination {
                    Text(item.destination.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, index == 0 ? 0 : 8)
                        .padding(.bottom, 2)
                }
                searchRow(
                    symbol: item.destination.symbol,
                    title: item.title,
                    detail: item.detail,
                    selected: index == searchSelection
                ) { open(item) }
            }
            if !pages.isEmpty {
                Text("Pages")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, results.isEmpty ? 0 : 8)
                ForEach(pages) { page in
                    searchRow(symbol: page.symbol, title: page.title, detail: nil, selected: false) {
                        select(page)
                        query = ""
                    }
                }
            }
            if !results.isEmpty {
                Text("↑↓ to move, ↩ to open")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }
        }
    }

    private func searchRow(
        symbol: String,
        title: String,
        detail: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 22, height: 22)
                    .background(
                        selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SettingsChrome.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ item: SettingsSearchItem) {
        select(item.destination)
        query = ""
        highlight = item.anchor
    }

    private var reportBugButton: some View {
        Button {
            NSWorkspace.shared.open(NanoLinks.reportBug)
        } label: {
            Label("Report a Bug", systemImage: "ant")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens a GitHub issue in your browser with your Nano and macOS versions filled in")
    }

    private var brand: some View {
        HStack(spacing: 8) {
            NanoMark()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Nano")
                    .font(.system(size: 12, weight: .semibold))
                if let creatorURL = Self.creatorURL {
                    Link("by \(Self.creatorHandle)", destination: creatorURL)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Visit \(Self.creatorHandle) on X")
                }
            }
        }
    }

    private func select(_ item: SettingsDestination, playIcon: Bool = true) {
        withAnimation(SettingsMotion.page(reduceMotion)) {
            destination = item
        }
        if playIcon {
            iconPlayToken[item, default: 0] += 1
        }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch destination ?? .general {
        case .general:
            GeneralSettingsPane(settings: settings, viewModel: viewModel, permissions: permissions, open: { select($0) })
        case .island:
            IslandSettingsPane(settings: settings, viewModel: viewModel)
        case .dashboard:
            DashboardSettingsPane(settings: settings, viewModel: viewModel)
        case .notifications:
            NotificationSettingsPane(settings: settings, viewModel: viewModel, permissions: permissions)
        case .agents:
            AgentSettingsPane(settings: settings, viewModel: viewModel)
        case .voiceDictation:
            VoiceDictationSettingsPane(settings: settings, controller: viewModel.voiceDictation)
        case .mixer:
            MixerSettingsPane(settings: settings, store: viewModel.mixerStore, viewModel: viewModel) { viewModel.openModule(.mixer) }
        case .cue:
            CueSettingsPane(settings: settings, store: viewModel.cueStore, viewModel: viewModel)
        case .permissions:
            PermissionsSettingsPane(monitor: permissions)
        case .privacy:
            PrivacySettingsPane(settings: settings, updates: viewModel.updateChecker, open: { select($0) })
        case .support:
            SupportSettingsPane()
        }
    }
}

private struct SettingsWindowClearBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}

/// Island hybrid recipe: liquid glass with a black wash so desktop color does not blow through.
struct SettingsWindowSurface: View {
    var reduceTransparency: Bool
    var colorScheme: ColorScheme

    private var glassIntensity: Double { 0.72 }
    private var blackOpacity: Double { 0.84 }

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                settingsGlass

                if colorScheme == .dark {
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(blackOpacity), location: 0),
                            .init(color: Color.black.opacity(blackOpacity * 0.92), location: 0.58),
                            .init(color: Color.black.opacity(0.68), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    // Nearly solid in light mode. A thin white wash left the
                    // window behind readable through the glass.
                    Color(nsColor: .windowBackgroundColor).opacity(0.94)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsGlass: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
                    .opacity(0.34 + (glassIntensity * 0.66))
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.34 + (glassIntensity * 0.66))
            }

            Color.black.opacity(colorScheme == .dark ? 0.035 + (glassIntensity * 0.145) : 0)
        }
    }
}

struct SettingsContentPaneBackground: View {
    var reduceTransparency: Bool
    var colorScheme: ColorScheme

    private var intensity: Double { 0.72 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .opacity(0.34 + (intensity * 0.66))
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .opacity(0.34 + (intensity * 0.66))
            }

            if !reduceTransparency {
                shape.fill(
                    colorScheme == .dark
                        ? Color.black.opacity(0.46)
                        : Color.white.opacity(0.10 + (intensity * 0.18))
                )
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @ObservedObject var permissions: NanoPermissionMonitor
    let open: (SettingsDestination) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let features: [NanoModuleID] = [.music, .calendar, .weather, .timer, .camera, .tray]
    private let addOns: [NanoModuleID] = [.agents, .voiceDictation, .cue, .mixer]

    var body: some View {
        SettingsPage(title: "General", symbol: "gearshape", subtitle: "How Nano opens, and what it shows.") {
            if !permissions.missing.isEmpty {
                SettingsBanner(
                    title: "\(permissions.missing.count) permission\(permissions.missing.count == 1 ? "" : "s") not granted",
                    detail: blockedDetail,
                    action: "Review"
                ) { open(.permissions) }
            }

            UpdateAvailableBanner(checker: viewModel.updateChecker)

            NanoSetupChecklistCard(settings: settings, viewModel: viewModel, open: open)

            SettingsSection("Opening") {
                LoginItemRow(loginItem: viewModel.loginItem)
                    .settingsAnchor("open.login")
                SettingsToggleRow(
                    "Require a click to open",
                    subtitle: settings.clickToOpen
                        ? "The dashboard stays closed until you click the island."
                        : "Hovering opens the island. A click keeps it open.",
                    isOn: $settings.clickToOpen
                )
                .settingsAnchor("open.click")
                SettingsToggleRow(
                    "Follow the active display",
                    subtitle: "Off keeps Nano on the display where you last placed it.",
                    isOn: $settings.followActiveDisplay
                )
                .settingsAnchor("open.display")
            }

            SettingsSection(
                "Shown in the island",
                trailing: "\(features.filter(settings.isEnabled).count) of \(features.count) on"
            ) {
                ForEach(features, id: \.self) { module in
                    featureRow(module)
                        .settingsAnchor("feature.\(module.rawValue)")
                }
            }

            SettingsSection("Add-ons", footer: "Each add-on gets its own page in the sidebar while it's on.") {
                ForEach(addOns, id: \.self) { module in
                    SettingsRow(module.title, symbol: module.symbol, subtitle: module.featureDescription) {
                        if settings.isEnabled(module), let page = page(for: module) {
                            Button("Settings…") { open(page) }
                                .controlSize(.small)
                        }
                        moduleToggle(module)
                    }
                    .settingsAnchor("addon.\(module.rawValue)")
                }
            }

            SettingsSection {
                SettingsRow("Replay setup", subtitle: "Walk through features and add-ons again. Your settings stay.") {
                    Button("Replay") {
                        NotificationCenter.default.post(name: .nanoReplayOnboarding, object: nil)
                    }
                    .controlSize(.small)
                }
                .settingsAnchor("setup.replay")
            }
        }
    }

    @ViewBuilder
    private func featureRow(_ module: NanoModuleID) -> some View {
        let blocker = settings.isEnabled(module) ? requiredPermission(module).flatMap { kind in
            permissions.missing.contains(kind) ? kind : nil
        } : nil
        // A Mac with no camera has nothing to preview. The switch stays usable
        // only to turn the feature off.
        let noCamera = module == .camera && permissions.state(for: .camera) == .unavailable

        SettingsRow(
            module.title,
            symbol: module.symbol,
            subtitle: noCamera
                ? "No camera is connected to this Mac."
                : (blocker.map { "Needs \($0.title) access" } ?? module.featureDescription),
            subtitleIsWarning: blocker != nil
        ) {
            if let blocker {
                Button("Grant") { permissions.handle(blocker) }
                    .controlSize(.small)
            }
            if module == .music, settings.isEnabled(.music) {
                Picker("Player", selection: $settings.preferredMediaPlayer) {
                    Text("Automatic").tag(MediaPlayerKind?.none)
                    ForEach(MediaPlayerKind.allCases) { player in
                        Text(player.title).tag(Optional(player))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help("Preferred music player")
            }
            moduleToggle(module)
                .disabled(noCamera && !settings.isEnabled(module))
        }
    }

    private func moduleToggle(_ module: NanoModuleID) -> some View {
        Toggle(module.title, isOn: Binding(
            get: { settings.isEnabled(module) },
            set: { enabled in
                withAnimation(SettingsMotion.accordion(reduceMotion)) {
                    settings.setEnabled(enabled, for: module)
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
    }

    private func requiredPermission(_ module: NanoModuleID) -> NanoPermissionKind? {
        switch module {
        case .calendar: .calendar
        case .weather: .location
        case .camera: .camera
        default: nil
        }
    }

    private func page(for module: NanoModuleID) -> SettingsDestination? {
        switch module {
        case .agents: .agents
        case .voiceDictation: .voiceDictation
        case .cue: .cue
        case .mixer: .mixer
        default: nil
        }
    }

    /// Names what the missing permissions switch off, most noticeable first.
    private var blockedDetail: String {
        let order: [NanoPermissionKind] = [
            .calendar, .location, .microphone, .fullDisk, .camera,
            .accessibility, .automation, .bluetooth, .contacts, .screenRecording, .reminders,
        ]
        let blocked = order.filter(permissions.missing.contains).map { kind in
            switch kind {
            case .calendar: "Calendar"
            case .location: "weather"
            case .microphone: "dictation"
            case .camera: "the camera preview"
            case .fullDisk: "macOS notifications"
            case .accessibility: "auto-paste"
            case .automation: "music controls"
            case .bluetooth: "accessory alerts"
            case .contacts: "sender photos"
            case .screenRecording: "Sketch"
            case .reminders: "Reminders sync"
            }
        }
        guard !blocked.isEmpty else { return "" }
        let named = Array(blocked.prefix(3))
        let rest = blocked.count - named.count
        var list: String
        if rest > 0 {
            list = named.joined(separator: ", ") + " and \(rest) more"
        } else if named.count == 1 {
            list = named[0]
        } else {
            list = named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        }
        list = list.prefix(1).uppercased() + list.dropFirst()
        return list + (blocked.count == 1 ? " is" : " are") + " off until you grant access."
    }
}

// MARK: - Island

private struct IslandSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @State private var focus: IslandPreviewFocus = .surface

    var body: some View {
        SettingsPage(
            title: "Island",
            symbol: SettingsDestination.island.symbol,
            subtitle: "Shape and surface. The preview follows what you change."
        ) {
            IslandLivePreview(settings: settings, focus: focus)

            VStack(alignment: .leading, spacing: 18) {
                    SettingsSection {
                        SettingsRow("Shape") {
                            Picker("Shape", selection: $settings.placement) {
                                ForEach(IslandPlacement.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .onHover { if $0 { focus = .shape } }
                        .settingsAnchor("island.shape")

                        SettingsRow("Surface") {
                            Picker("Surface", selection: $settings.appearance) {
                                ForEach(IslandAppearance.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .onHover { if $0 { focus = .surface } }
                        .settingsAnchor("island.surface")
                    }

                    SettingsSection(settings.appearance.title) {
                        colorRow("Surface color", value: $settings.surfaceColor, focus: .surfaceColor)
                            .settingsAnchor("island.surfaceColor")
                        if settings.appearance != .solidBlack {
                            colorRow(
                                settings.appearance == .hybrid ? "Lower gradient tint" : "Glass tint",
                                value: $settings.glassTintColor,
                                focus: .tint
                            )
                            .settingsAnchor("island.tint")
                        }
                        sliderRow("Surface opacity", value: $settings.blackOpacity, range: 0.55...1, focus: .opacity)
                            .settingsAnchor("island.opacity")
                        if settings.appearance != .solidBlack {
                            sliderRow("Glass intensity", value: $settings.blurIntensity, range: 0...1, focus: .glass)
                                .settingsAnchor("island.glass")
                        }
                        if settings.appearance == .hybrid {
                            sliderRow("Gradient midpoint", value: $settings.gradientMidpoint, range: 0.25...0.8, focus: .midpoint)
                                .settingsAnchor("island.midpoint")
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Reset Appearance") { settings.resetAppearance() }
                            .controlSize(.small)
                    }
                    .settingsAnchor("island.reset")
            }
        }
    }

    private func colorRow(_ title: String, value: Binding<NanoColorValue>, focus target: IslandPreviewFocus) -> some View {
        SettingsRow(title) {
            ColorPicker(title, selection: Binding(
                get: { value.wrappedValue.color },
                set: { value.wrappedValue = NanoColorValue(color: $0) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
        .onHover { if $0 { focus = target } }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        focus target: IslandPreviewFocus
    ) -> some View {
        SettingsRow(title) {
            Slider(value: value, in: range) { editing in
                if editing { focus = target }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 200)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .onHover { if $0 { focus = target } }
    }
}

private enum IslandPreviewFocus {
    case shape, surface, surfaceColor, tint, opacity, glass, midpoint

    var title: String {
        switch self {
        case .shape: "Shape"
        case .surface: "Surface"
        case .surfaceColor: "Surface color"
        case .tint: "Tint"
        case .opacity: "Surface opacity"
        case .glass: "Glass intensity"
        case .midpoint: "Gradient midpoint"
        }
    }

    var detail: String {
        switch self {
        case .shape: "Notch hangs from the top edge. Floating sits just below it."
        case .surface: "Solid Black hides the wallpaper. Glass lets it through. Hybrid is black on top, glass at the bottom."
        case .surfaceColor: "The island's base color. Black matches the notch."
        case .tint: "Colors the glass, and the lower edge of Hybrid."
        case .opacity: "Lower lets more of the wallpaper through."
        case .glass: "How strongly the glass blurs what's behind it."
        case .midpoint: "Where Hybrid's black gives way to glass."
        }
    }
}

/// The island over a wallpaper at the dashboard's real proportions (760 by
/// 300), drawn with the live appearance values.
private struct IslandLivePreview: View {
    @ObservedObject var settings: NanoSettings
    let focus: IslandPreviewFocus

    private var attached: Bool { settings.placement == .attached }
    private let sceneHeight: CGFloat = 230
    private let islandWidth: CGFloat = 380
    private var islandScale: CGFloat { islandWidth / 760 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0.24, green: 0.33, blue: 0.55),
                        Color(red: 0.36, green: 0.22, blue: 0.42),
                        Color(red: 0.12, green: 0.10, blue: 0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "apple.logo")
                        Text("Finder").fontWeight(.semibold)
                        Text("File   Edit   View").foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text("Thu 9:41")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(Color.black.opacity(0.22))
                    Spacer()
                }
                island
                    .padding(.top, attached ? 0 : 28)
            }
            .frame(maxWidth: .infinity)
            .frame(height: sceneHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            }
            .environment(\.colorScheme, .dark)
            .accessibilityLabel("Island preview")
            .animation(.easeOut(duration: 0.25), value: settings.placement)

            VStack(alignment: .leading, spacing: 2) {
                Text(focus.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(focus.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(nil, value: focus)
        }
    }

    /// Drawn at full size, then scaled, so corner radii and spacing keep the
    /// real island's proportions.
    private var island: some View {
        // The real island's geometry: the same inset on every side, its corner
        // radius, and room for the notch only when it hangs from one.
        let inset = DashboardLayout.inset
        let notchRoom: CGFloat = attached ? 22 : 0
        let radius = IslandHitGeometry.cornerRadius(expanded: true)
        let size = CGSize(width: 760, height: notchRoom + DashboardLayout.fullHeight + inset * 2)
        let shape = attached
            ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        let filled = DashboardLayout.filledAreas(settings)
        return ZStack(alignment: .topLeading) {
            IslandSurfaceBackground(
                appearance: settings.appearance,
                blackOpacity: settings.blackOpacity,
                glassIntensity: settings.blurIntensity,
                gradientMidpoint: settings.gradientMidpoint,
                surfaceColor: settings.surfaceColor,
                glassTintColor: settings.glassTintColor,
                cornerRadius: radius
            )
            // The dashboard's slots as plain wells, where they really sit.
            let placements = DashboardLayout.placements(
                width: size.width - inset * 2,
                filled: filled.isEmpty ? Set(DashboardArea.allCases) : filled
            )
            ForEach(DashboardArea.allCases) { area in
                if let frame = placements[area]?.frame {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Color.white.opacity(settings.appearance == .glass ? 0.12 : 0.07))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX + inset, y: frame.minY + inset + notchRoom)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay { shape.stroke(Color.white.opacity(settings.appearance == .solidBlack ? 0.08 : 0.2), lineWidth: 1.2) }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .scaleEffect(islandScale, anchor: .top)
        .frame(width: islandWidth, height: size.height * islandScale, alignment: .top)
    }
}

// MARK: - Dashboard

private struct DashboardSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @State private var confirmingRestore = false

    var body: some View {
        SettingsPage(
            title: "Dashboard",
            symbol: SettingsDestination.dashboard.symbol,
            subtitle: "Drag features into slots, or click a slot to choose.",
            trailing: AnyView(HStack(spacing: 8) {
                Button("Restore Default") { confirmingRestore = true }
                    .confirmationDialog("Restore the default dashboard?", isPresented: $confirmingRestore) {
                        Button("Restore default", role: .destructive) { settings.resetDashboardLayout() }
                    } message: {
                        Text("Your current layout is replaced.")
                    }
                Button(viewModel.phase == .pinnedDashboard ? "Close Dashboard" : "Open Dashboard") {
                    viewModel.togglePinnedDashboard()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small))
        ) {
            SettingsCard {
                DashboardEditor(settings: settings, viewModel: viewModel)
            }
            .settingsAnchor("dashboard.editor")
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @ObservedObject var permissions: NanoPermissionMonitor

    var body: some View {
        SettingsPage(
            title: "Notifications",
            symbol: "bell",
            subtitle: "Events that open the island on their own. Click a preview to see it live."
        ) {
            SettingsSection("Events") {
                ForEach(visibleSources, id: \.self) { source in
                    let needsAccess = source == .system && permissions.missing.contains(.fullDisk)
                    SettingsRow(
                        source.title,
                        symbol: source.symbol,
                        subtitle: needsAccess ? "Needs Full Disk Access" : summary(source),
                        subtitleIsWarning: needsAccess
                    ) {
                        previewButton(source)
                        Toggle(source.title, isOn: Binding(
                            get: { settings.isNotificationEnabled(source) },
                            set: { settings.setNotificationEnabled($0, for: source) }
                        ))
                        .labelsHidden()
                        .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
                    }
                    .settingsAnchor("notif.\(source.rawValue)")
                }
            }

            if settings.isNotificationEnabled(.volume) || settings.isNotificationEnabled(.brightness) {
                MediaKeySettingsCard(settings: settings, viewModel: viewModel)
                    .settingsAnchor("notif.mediaKeys")
            }

            if settings.isNotificationEnabled(.system) {
                SystemNotificationSettingsCard(settings: settings, viewModel: viewModel)
            }

            if settings.isEnabled(.agents) {
                Text("Agent updates stay for six seconds. Approvals and questions stay until you answer.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ source: IslandNotificationSource) -> String {
        switch source {
        case .volume: "When the volume keys change"
        case .brightness: "When the brightness keys change"
        case .bluetooth: "AirPods, mice, and keyboards connecting"
        case .battery: "When a laptop starts charging"
        case .timer: "When a timer finishes"
        case .agent: "Finished, needs approval, or has a question"
        case .system: "iMessage, calls, Mail, and every other app"
        }
    }

    /// The pill is the preview button. Sources with variants list them on
    /// right-click; a plain click shows the most common one.
    private func previewButton(_ source: IslandNotificationSource) -> some View {
        Button {
            previewDefault(source)
        } label: {
            NotificationPreviewPill(source: source, isOn: settings.isNotificationEnabled(source))
        }
        .buttonStyle(.plain)
        .help(hasVariants(source) ? "Show on the island. Right-click for more." : "Show on the island")
        .contextMenu { variants(source) }
        .accessibilityLabel("Preview \(source.title)")
    }

    private func hasVariants(_ source: IslandNotificationSource) -> Bool {
        source == .agent || source == .bluetooth || source == .system
    }

    private func previewDefault(_ source: IslandNotificationSource) {
        switch source {
        case .agent:
            viewModel.previewNotification(.agentPreview(provider: .claude, kind: .completion))
        case .bluetooth:
            previewBluetooth(name: "AirPods Pro", category: .headphones)
        case .system:
            if let first = IslandNotification.SystemPreviewKind.allCases.first {
                viewModel.previewNotification(.systemPreview(kind: first))
            }
        default:
            viewModel.previewNotification(source)
        }
    }

    @ViewBuilder
    private func variants(_ source: IslandNotificationSource) -> some View {
        switch source {
        case .agent:
            Button("New agent found") {
                viewModel.previewNotification(.agentSetup(provider: .gemini))
            }
            Divider()
            ForEach(AgentProviderID.supported) { provider in
                Menu(provider.title) {
                    Button("Approval") {
                        viewModel.previewNotification(.agentPreview(provider: provider, kind: .permission))
                    }
                    Button("Question") {
                        viewModel.previewNotification(.agentPreview(provider: provider, kind: .question))
                    }
                    Button("Completed") {
                        viewModel.previewNotification(.agentPreview(provider: provider, kind: .completion))
                    }
                    if provider == .claude {
                        Button("Plan") {
                            viewModel.previewNotification(.agentPlanPreview(provider: provider))
                        }
                    }
                }
            }
        case .bluetooth:
            Button("AirPods Pro") { previewBluetooth(name: "AirPods Pro", category: .headphones) }
            Button("AirPods Max") { previewBluetooth(name: "AirPods Max", category: .headphones) }
            Button("Magic Keyboard") { previewBluetooth(name: "Magic Keyboard with Touch ID", category: .keyboard) }
            Button("Magic Mouse") { previewBluetooth(name: "Magic Mouse", category: .mouse) }
        case .system:
            ForEach(IslandNotification.SystemPreviewKind.allCases) { kind in
                Button(kind.title) { viewModel.previewNotification(.systemPreview(kind: kind)) }
            }
        default:
            Button("Show on the island") { viewModel.previewNotification(source) }
        }
    }

    private func previewBluetooth(name: String, category: BluetoothAccessoryCategory) {
        viewModel.previewNotification(
            .bluetooth(
                name: name,
                category: category,
                connected: true,
                address: "settings-preview:\(category.rawValue):\(name)"
            )
        )
    }

    private var visibleSources: [IslandNotificationSource] {
        IslandNotificationSource.allCases.filter(settings.isNotificationSourceAvailable)
    }
}

/// Everything specific to mirroring macOS notifications: access, quiet
/// rules, iMessage extras, and the per-app mute list.
private struct MediaKeySettingsCard: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @ObservedObject private var interceptor: MediaKeyInterceptor

    init(settings: NanoSettings, viewModel: IslandViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        _interceptor = ObservedObject(wrappedValue: viewModel.mediaKeyInterceptor)
    }

    var body: some View {
        SettingsCard(spacing: 12) {
            SettingsGroupTitle(
                title: "Media keys",
                detail: "Let Nano handle the volume and brightness keys so only its HUD appears."
            )

            Toggle(isOn: $settings.hudReplacesSystemHUD) {
                labeled("Replace the macOS HUD", replaceDetail)
            }
            .onChange(of: settings.hudReplacesSystemHUD) { _, on in
                if on { NanoAccessibilityPermission.requestIfNeeded() }
            }
            if interceptor.status == .needsAccessibility {
                Button("Open Accessibility Settings") {
                    NanoAccessibilityPermission.requestIfNeeded()
                }
                .font(.system(size: 12))
            }

            if settings.hudReplacesSystemHUD {
                let noAdjustableDisplay = DisplayBrightnessService.controllableDisplay == nil
                Toggle(isOn: $settings.hudReplacesVolumeKeys) {
                    labeled("Volume keys", "Including mute. Option-Shift steps in quarter increments, like macOS.")
                }
                Toggle(isOn: $settings.hudReplacesBrightnessKeys) {
                    labeled(
                        "Brightness keys",
                        noAdjustableDisplay
                            ? "No adjustable display found, so macOS keeps handling these keys."
                            : "Adjusts the built-in display."
                    )
                }
                .disabled(noAdjustableDisplay)
                Toggle(isOn: $settings.hudVolumeFeedbackSound) {
                    labeled("Play feedback sound", "The macOS tick when the volume changes.")
                }
            }
        }
    }

    private var replaceDetail: String {
        switch interceptor.status {
        case .needsAccessibility:
            "Needs Accessibility. Nano takes over the keys only after it is allowed to control your Mac."
        case .failed:
            "The key intercept could not start. Try turning it off and on."
        default:
            "Volume and brightness keys go to Nano first. Sliders in Control Center still show the Apple HUD."
        }
    }

    private func labeled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SystemNotificationSettingsCard: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @ObservedObject private var store: NotificationCenterStore
    @ObservedObject private var contacts: ContactPhotoProvider
    @ObservedObject private var suppressor: NativeBannerSuppressor
    @State private var tick = 0

    init(settings: NanoSettings, viewModel: IslandViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.notificationStore)
        _contacts = ObservedObject(wrappedValue: viewModel.contactPhotos)
        _suppressor = ObservedObject(wrappedValue: viewModel.bannerSuppressor)
    }

    var body: some View {
        let _ = tick
        SettingsCard(spacing: 12) {
            accessRow
            Divider()

            Toggle(isOn: $settings.systemNotificationsShowBody) {
                labeled("Show message text", "Display the body of each notification, not only its title.")
            }
            Toggle(isOn: $settings.systemNotificationsShowActions) {
                labeled(
                    "Show app buttons",
                    "Complete, Archive, Snooze and other buttons the app registered appear on the card. They press the matching macOS banner button, so they work best with the banner visible."
                )
            }
            Toggle(isOn: $settings.systemNotificationsHidePreviewsOnCamera) {
                labeled(
                    "Hide previews while the camera is on",
                    "While any app is using the camera, as on a FaceTime or Zoom call, cards show only the app name. Sharing your screen without the camera is not covered."
                )
            }
            .onChange(of: settings.systemNotificationsHidePreviewsOnCamera) { _, on in
                if on { viewModel.cameraMonitor.start() } else { viewModel.cameraMonitor.stop() }
            }
            Toggle(isOn: $settings.systemNotificationsCatchUp) {
                labeled(
                    "Catch up after sleep or lock",
                    "One \"While you were away\" card sums up what arrived while the Mac was asleep or locked. Tap it to open the Notifications history."
                )
            }
            Toggle(isOn: $settings.systemNotificationsHideNativeBanner) {
                labeled(
                    "Handle notifications with Nano",
                    NanoAccessibilityPermission.isTrusted
                        ? "Keep agent actions in Nano and dismiss matching native banners when macOS allows it."
                        : "Close the matching macOS banner once the island shows it. Needs Accessibility, which Nano already asks for."
                )
            }

            if settings.systemNotificationsHideNativeBanner {
                if let status = suppressor.setupStatus {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(suppressor.issues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Banner setup needed for \(issue.appName)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(issue.outcome == .grouped
                             ? "macOS only offers a group-wide dismissal. Set up for me turns off this app’s Desktop banners while keeping Allow Notifications and Notification Center on. You can restore Desktop banners in macOS settings."
                             : "Nano could not verify that this banner disappeared. Check Accessibility access or turn off this app's Desktop banners while leaving Allow Notifications on.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            Button("Set up for me") {
                                Task { await suppressor.configureDesktopBanners(for: issue, storeReady: store.access == .ready) }
                            }
                            .disabled(suppressor.setupInProgress || store.access != .ready)
                            Button("Open settings") { suppressor.openSettings(for: issue) }
                        }
                    }
                }
            }

            Divider()
            Text("Calls")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("FaceTime and iPhone calls show who is ringing while the macOS banner is up. Answer or decline on that banner; macOS gives no other way to do it. Tap the card to open FaceTime. Add FaceTime or Phone to Muted apps below to turn this off.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CallWatcherDiagnosticsRow(watcher: viewModel.callWatcher)

            Divider()
            Text("iMessage")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: $settings.systemNotificationsInlineReply) {
                labeled("Reply from the island", "Type a reply inside the card. macOS asks once to let Nano control Messages.")
            }
            Toggle(isOn: $settings.systemNotificationsContactPhotos) {
                labeled("Sender photos", contactsDetail)
            }
            Toggle(isOn: $settings.systemNotificationsMarkReadAfterReply) {
                labeled(
                    "Mark read after replying",
                    "Open the conversation in Messages behind your windows once a reply sends, so the unread badge clears. Messages may show its window."
                )
            }
            .onChange(of: settings.systemNotificationsContactPhotos) { _, on in
                if on { contacts.requestAccess() }
            }
            if settings.systemNotificationsContactPhotos, contacts.authorization != .authorized {
                Button(contacts.authorization == .notDetermined ? "Allow Contacts" : "Open Contacts privacy settings") {
                    if contacts.authorization == .notDetermined {
                        contacts.requestAccess()
                    } else {
                        openPrivacySettings("Privacy_Contacts")
                    }
                }
                .font(.system(size: 12))
            }

            Divider()
            excludedApps

            Text("Tip: in System Settings → Notifications, set an app's alert style to None but keep Allow Notifications on. macOS still records it, so it reaches the island without a second banner.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            contacts.refreshAuthorization()
            viewModel.notificationStore.refresh()
            tick += 1
        }
    }

    private var contactsDetail: String {
        switch contacts.authorization {
        case .authorized: "Show the sender's contact photo on iMessage cards."
        case .notDetermined: "Show the sender's contact photo on iMessage cards. Asks for Contacts access."
        default: "Contacts access is off for Nano. Allow it in System Settings to show sender photos."
        }
    }

    @ViewBuilder
    private var accessRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: accessSymbol)
                .foregroundStyle(accessTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(accessTitle).font(.system(size: 13, weight: .semibold))
                Text(accessDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if store.access != .ready {
                Button("Open Full Disk Access") {
                    openPrivacySettings(NanoPermissionKind.fullDisk.settingsAnchor)
                }
            }
        }
    }

    private var accessTitle: String {
        switch store.access {
        case .ready: "Capturing macOS notifications"
        case .needsFullDiskAccess: "Needs Full Disk Access"
        case .unavailable: "Notification store unavailable"
        case .idle: "Not running"
        }
    }

    private var accessDetail: String {
        switch store.access {
        case .ready:
            "New notifications from any app appear in the island as they arrive."
        case .needsFullDiskAccess:
            "Add Nano under System Settings → Privacy & Security → Full Disk Access. If Nano is already listed, turn it off and on again, then relaunch Nano."
        case .unavailable:
            "macOS did not expose a readable notification store. Nano keeps retrying."
        case .idle:
            "Turn on Notifications above to start."
        }
    }

    private var accessSymbol: String {
        store.access == .ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var accessTint: Color {
        store.access == .ready ? Color(red: 0.20, green: 0.78, blue: 0.35) : .orange
    }

    @ViewBuilder
    private var excludedApps: some View {
        HStack {
            Text("Muted apps")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Add app…") { pickApp() }
                .font(.system(size: 12))
        }
        let excluded = settings.systemNotificationExcludedApps.sorted {
            SystemNotificationAppInfo.name(for: $0).localizedCaseInsensitiveCompare(
                SystemNotificationAppInfo.name(for: $1)
            ) == .orderedAscending
        }
        if excluded.isEmpty {
            Text("Every app comes through. Mute an app here or from a card in the Notifications history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(excluded, id: \.self) { bundleID in
                HStack(spacing: 10) {
                    if let icon = SystemNotificationAppInfo.icon(for: bundleID) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 18)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(SystemNotificationAppInfo.name(for: bundleID)).font(.system(size: 12.5))
                        Text(bundleID).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Unmute") {
                        settings.setSystemNotificationExcluded(false, bundleID: bundleID)
                        viewModel.syncNotificationSources()
                    }
                    .font(.system(size: 12))
                }
            }
        }

        let recentApps = recentSystemApps.filter { !settings.isSystemNotificationExcluded(bundleID: $0) }
        if !recentApps.isEmpty {
            Text("Recently seen")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            ForEach(recentApps, id: \.self) { bundleID in
                HStack(spacing: 10) {
                    if let icon = SystemNotificationAppInfo.icon(for: bundleID) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 18)
                    }
                    Text(SystemNotificationAppInfo.name(for: bundleID)).font(.system(size: 12.5))
                    Spacer()
                    Button("Mute") {
                        settings.setSystemNotificationExcluded(true, bundleID: bundleID)
                        viewModel.syncNotificationSources()
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private var recentSystemApps: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for item in viewModel.notificationCenter.recents {
            guard let content = item.systemContent, content.recordID >= 0 else { continue }
            if seen.insert(content.bundleID).inserted { ordered.append(content.bundleID) }
        }
        return Array(ordered.prefix(6))
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Mute"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            settings.setSystemNotificationExcluded(true, bundleID: bundleID)
        }
        viewModel.syncNotificationSources()
    }

    private func labeled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AgentSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @State private var showsHooks = false
    @State private var installedHookCount = 0

    var body: some View {
        SettingsPage(
            title: "Agents",
            symbol: "terminal",
            subtitle: "Which coding agents Nano watches, and how usage reads."
        ) {
            if installedHookCount == 0, !AgentHookBridge.installationProviders(AgentHookReviewSheet.hookable).isEmpty {
                SettingsBanner(
                    title: "Live approvals are off",
                    detail: "Without hooks, Nano sees sessions but can't show approvals or questions.",
                    action: "Review…"
                ) { showsHooks = true }
            }

            SettingsSection("Display") {
                SettingsRow("Show quota as") {
                    Picker("Show quota as", selection: $settings.usageDisplayMode) {
                        ForEach(UsageDisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .settingsAnchor("agents.quota")
                SettingsRow(
                    "Live hooks",
                    subtitle: installedHookCount == 0
                        ? "Not installed. Sessions are still found without them."
                        : "Installed in \(installedHookCount) config file\(installedHookCount == 1 ? "" : "s")"
                ) {
                    Button("Manage…") { showsHooks = true }
                        .controlSize(.small)
                }
                .settingsAnchor("agents.hooks")
            }

            SettingsCard {
                ClaudeLocalUsageRow(settings: settings, service: viewModel.agentService)
            }
            .settingsAnchor("agents.claudeUsage")

            SettingsSection(
                "Agents",
                trailing: "\(AgentProviderID.supported.filter(settings.isAgentProviderEnabled).count) tracked",
                footer: "Sessions shows an agent's sessions, approvals and token counts. Usage checks each plan's remaining quota after an agent finishes a turn, and about every 12 minutes otherwise. Cline, Qwen Code, Kilo Code, and Goose show while they run, but can't be answered from the island yet."
            ) {
                ForEach(AgentProviderID.supported) { provider in
                    providerRow(provider)
                }
            }
            .settingsAnchor("agents.providers")
        }
        .onAppear(perform: refreshHooks)
        .sheet(isPresented: $showsHooks, onDismiss: refreshHooks) {
            AgentHookReviewSheet(
                bridge: viewModel.hookBridge,
                settings: settings,
                agentService: viewModel.agentService
            ) { showsHooks = false }
        }
        .onAppear {
            if viewModel.requestsHookReview {
                viewModel.requestsHookReview = false
                showsHooks = true
            }
        }
        .onChange(of: viewModel.requestsHookReview) { _, requested in
            guard requested else { return }
            viewModel.requestsHookReview = false
            showsHooks = true
        }
    }

    private func providerRow(_ provider: AgentProviderID) -> some View {
        HStack(spacing: 11) {
            AgentBrandMark(provider: provider, size: 18)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(provider.title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsChipToggle(title: "Sessions", isOn: Binding(
                get: { settings.isAgentProviderEnabled(provider) },
                set: { enabled in
                    settings.setAgentProviderEnabled(enabled, provider: provider)
                    viewModel.agentService.activate(
                        providers: settings.enabledAgentProviders,
                        usage: settings.usageProviders
                    )
                    if enabled {
                        viewModel.scanTokenLedger()
                    }
                }
            ))
            .help("Show this agent's sessions, approvals and token counts.")
            SettingsChipToggle(
                title: "Usage",
                isOn: Binding(
                    get: { settings.isUsageEnabled(provider) },
                    set: { enabled in
                        settings.setUsageEnabled(enabled, provider: provider)
                        viewModel.agentService.updateUsageProviders(settings.usageProviders)
                    }
                ),
                isEnabled: provider.supportsUsage
            )
            .help(provider.supportsUsage ? "Read remaining quota from \(provider.title)" : provider.usageUnavailableHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }

    private func refreshHooks() {
        installedHookCount = AgentHookBridge.installedHookConfigURLs().count
    }
}

/// Review sheet for Nano's agent hooks: which agents are on this Mac, the
/// exact files Nano edits for each, and what it adds. Nothing is written until
/// the user confirms, and the same sheet removes everything again.
///
/// macOS offers no uninstall hook, so the undo has to live here, next to the
/// agents it concerns, naming the files rather than describing them.
struct AgentHookReviewSheet: View {
    @ObservedObject var bridge: AgentHookBridge
    @ObservedObject var settings: NanoSettings
    @ObservedObject var agentService: AgentStatusService
    let done: () -> Void

    @State private var selected: Set<AgentProviderID> = []
    @State private var installed: Set<URL> = []
    @State private var confirmsRemoval = false
    /// The one agent a row's Remove button asked about.
    @State private var removing: AgentProviderID?

    static let hookable = Set(AgentHookBridge.hookableProviders)

    /// Files Nano creates outright, rather than adding entries to the user's own.
    private static let ownedFiles: Set<AgentProviderID> = [.grok, .opencode]

    private var providers: [AgentProviderID] {
        AgentHookBridge.installationProviders(Self.hookable)
    }

    private func files(_ provider: AgentProviderID) -> [URL] {
        AgentHookBridge.installationConfigURLs(for: [provider]).map(\.standardizedFileURL)
    }

    private func isConnected(_ provider: AgentProviderID) -> Bool {
        let urls = files(provider)
        return !urls.isEmpty && urls.allSatisfy(installed.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect agents to Nano")
                    .font(.system(size: 15, weight: .semibold))
                Text("Nano adds a small hook to each agent's settings so approvals, questions, and finished turns reach the island. Nothing else in these files changes, and shared files are backed up first.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if providers.isEmpty {
                SettingsCard {
                    Text("None of the agents Nano supports are installed on this Mac yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    SettingsSection {
                        ForEach(providers) { provider in
                            row(provider)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 360)
            }

            Text("Agents Nano didn't find on this Mac aren't listed. Codex may ask you to approve new hooks with /hooks before it sends events.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !installed.isEmpty {
                    Button("Remove All…", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                Button(selected.isEmpty ? "Done" : "Not Now", action: done)
                    .keyboardShortcut(.cancelAction)
                Button(connectTitle) {
                    bridge.installHooks(for: selected)
                    for provider in selected {
                        settings.setAgentProviderEnabled(true, provider: provider)
                    }
                    agentService.activate(providers: settings.enabledAgentProviders, usage: settings.usageProviders)
                    refresh()
                    selected = []
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || !settings.isEnabled(.agents))
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            refresh()
            // Suggest the agents Nano already tracks that aren't connected yet.
            selected = Set(providers.filter { settings.isAgentProviderEnabled($0) && !isConnected($0) })
        }
        .confirmationDialog(
            "Remove Nano's hooks from \(installed.count) file\(installed.count == 1 ? "" : "s")?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                bridge.uninstallHooks()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nano removes only its own entries and plugins. Running agents may need restarting. Sessions are still found without hooks.")
        }
        .confirmationDialog(
            "Disconnect \(removing?.title ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let removing { bridge.uninstallHooks(for: [removing]) }
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nano removes only its own hook for \(removing?.title ?? "this agent"). A running session may need restarting. It's still found without the hook.")
        }
    }

    private var connectTitle: String {
        selected.count == 1 ? "Connect 1 Agent" : "Connect \(selected.count) Agents"
    }

    private func row(_ provider: AgentProviderID) -> some View {
        let connected = isConnected(provider)
        return HStack(alignment: .top, spacing: 11) {
            if connected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 16)
                    .padding(.top, 4)
            } else {
                Toggle(provider.title, isOn: Binding(
                    get: { selected.contains(provider) },
                    set: { on in
                        if on { selected.insert(provider) } else { selected.remove(provider) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 4)
            }
            AgentBrandMark(provider: provider, size: 18)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.title).font(.system(size: 13, weight: .medium))
                    if connected {
                        Text("Connected")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
                ForEach(files(provider), id: \.self) { url in
                    Text(Self.display(url))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Label(
                    Self.ownedFiles.contains(provider)
                        ? "A new file that belongs to Nano"
                        : "Adds Nano's hooks next to yours. Backup: .nano-bak",
                    systemImage: Self.ownedFiles.contains(provider) ? "doc.badge.plus" : "plus.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if connected {
                Button("Remove") { removing = provider }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func refresh() {
        installed = Set(AgentHookBridge.installedHookConfigURLs().map(\.standardizedFileURL))
    }

    /// Shown relative to home: the absolute path is mostly the user's own name
    /// repeated, and `~/.claude/settings.json` is the form they would recognise.
    static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}

/// Tips are optional and unlock nothing; the page says so first.
struct SupportSettingsPane: View {
    var body: some View {
        SettingsPage(
            title: "Support Nano",
            symbol: "heart",
            subtitle: "Nano is free and open source, with no paywall, trial or account."
        ) {
            SettingsCard(spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    NanoMark()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("If Nano saves you time, you can buy me a coffee")
                            .font(.system(size: 15, weight: .semibold))
                        Text("A one-time tip on Ko-fi helps me keep building Nano and the other tools I make. It's never needed, and Nano works exactly the same either way, but every tip is greatly appreciated.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Link(destination: NanoLinks.tip) {
                        Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(SettingsChrome.accent, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.nanoPress)
                    .help("Opens ko-fi.com/valenxi in your browser")
                    Text("ko-fi.com/valenxi")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                // Lined up with the text, not the mark.
                .padding(.leading, 54)
            }
            .settingsAnchor("support.tip")

            SettingsSection("Other ways to help", footer: "All of these are free.") {
                SettingsRow("Star Nano on GitHub", symbol: "star", subtitle: "Helps other people find it") {
                    Button("Open…") { NSWorkspace.shared.open(NanoLinks.sourceCode) }
                        .controlSize(.small)
                }
                SettingsRow("See my other projects", symbol: "square.stack.3d.up", subtitle: "Quill for Windows and the rest of my public repos") {
                    Button("Open…") { NSWorkspace.shared.open(NanoLinks.otherProjects) }
                        .controlSize(.small)
                }
                .settingsAnchor("support.projects")
                SettingsRow("Report a bug or share an idea", symbol: "ladybug") {
                    Button("Report…") { NSWorkspace.shared.open(NanoLinks.reportBug) }
                        .controlSize(.small)
                }
                if let creator = NanoSettingsView.creatorURL {
                    SettingsRow("Follow \(NanoSettingsView.creatorHandle)", symbol: "at", subtitle: "Updates and what I'm working on") {
                        Button("Open…") { NSWorkspace.shared.open(creator) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct PrivacySettingsPane: View {
    @ObservedObject var settings: NanoSettings
    let updates: NanoUpdateChecker
    let open: (SettingsDestination) -> Void

    var body: some View {
        SettingsPage(
            title: "Privacy & About",
            symbol: "lock.shield",
            subtitle: "What Nano stores, and what it never sends."
        ) {
            SettingsCard {
                HStack(spacing: 14) {
                    NanoMark()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nano")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Version \(NanoAppInfo.version) (\(NanoAppInfo.build))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = NanoSettingsView.creatorURL {
                        Link("Made by \(NanoSettingsView.creatorHandle)", destination: url)
                            .font(.system(size: 12))
                    }
                }
            }
            .settingsAnchor("privacy.about")

            SettingsSection("Updates") {
                SettingsToggleRow(
                    "Check for updates automatically",
                    subtitle: "Once a day Nano asks GitHub for the latest release. Nothing about you is sent.",
                    isOn: $settings.checksForUpdates
                )
                .settingsAnchor("updates.automatic")
                UpdateStatusRow(checker: updates)
                    .settingsAnchor("updates.check")
            }
            .onChange(of: settings.checksForUpdates) { _, isOn in
                if isOn { updates.checkIfDue() }
            }

            SettingsSection("Feedback", footer: "Opens a GitHub issue in your browser, with your Nano and macOS versions filled in.") {
                SettingsRow("Report a bug", symbol: "ant") {
                    Button("Report…") { NSWorkspace.shared.open(NanoLinks.reportBug) }
                        .controlSize(.small)
                }
                .settingsAnchor("feedback.bug")
                SettingsRow("Request a feature", symbol: "lightbulb") {
                    Button("Request…") { NSWorkspace.shared.open(NanoLinks.requestFeature) }
                        .controlSize(.small)
                }
            }

            SettingsSection("Privacy") {
                SettingsRow("No account, no analytics, no ads", symbol: "checkmark.shield")
                SettingsRow("Agents, cues, and dictation stay on this Mac", symbol: "internaldrive")
                SettingsRow("Usage checks go straight to each agent's provider", symbol: "arrow.left.arrow.right")
                SettingsRow("Weather sends only your saved location", symbol: "location")
            }

            SettingsSection("Related") {
                SettingsRow("Permissions", symbol: "hand.raised", subtitle: "Calendar, camera, microphone, and the rest") {
                    Button("Open") { open(.permissions) }
                        .controlSize(.small)
                }
                if settings.isEnabled(.agents) {
                    SettingsRow("Agent hooks", symbol: "terminal", subtitle: "Review or remove the files Nano edits") {
                        Button("Open") { open(.agents) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Open at login, read live from the system's Login Items.
private struct LoginItemRow: View {
    @ObservedObject var loginItem: NanoLoginItem

    var body: some View {
        SettingsRow(
            "Open at login",
            subtitle: subtitle,
            subtitleIsWarning: loginItem.needsApproval || loginItem.errorMessage != nil
        ) {
            if loginItem.needsApproval {
                Button("Login Items…", action: loginItem.openLoginItemsSettings)
                    .controlSize(.small)
            }
            Toggle("Open at login", isOn: Binding(
                get: { loginItem.isEnabled || loginItem.needsApproval },
                set: { loginItem.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
        }
        .onAppear(perform: loginItem.refresh)
        // Login Items can change in System Settings while this page is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var subtitle: String {
        if let error = loginItem.errorMessage { return error }
        if loginItem.needsApproval { return "Blocked in System Settings → General → Login Items. Allow Nano there." }
        return loginItem.isEnabled ? "Nano starts when you log in." : "You open Nano yourself after each restart."
    }
}

private struct UpdateAvailableBanner: View {
    @ObservedObject var checker: NanoUpdateChecker

    var body: some View {
        if let update = checker.available {
            SettingsBanner(
                title: "Nano \(update.version) is available",
                detail: "You have \(NanoAppInfo.version). The download opens in your browser.",
                action: "Download",
                perform: checker.download
            )
        }
    }
}

private struct UpdateStatusRow: View {
    @ObservedObject var checker: NanoUpdateChecker

    var body: some View {
        SettingsRow(title, subtitle: subtitle, subtitleIsWarning: isFailure) {
            if checker.available != nil {
                Button("Download", action: checker.download)
                    .controlSize(.small)
            } else {
                Button("Check Now", action: checker.checkNow)
                    .controlSize(.small)
                    .disabled(checker.status == .checking)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = checker.status { return true }
        return false
    }

    private var title: String {
        switch checker.status {
        case .idle: "Nano \(NanoAppInfo.version)"
        case .checking: "Checking for updates…"
        case .current: "Nano \(NanoAppInfo.version) is up to date"
        case .noReleases: "No updates published yet"
        case let .available(update): "Nano \(update.version) is available"
        case .failed: "Couldn't check for updates"
        }
    }

    private var subtitle: String? {
        switch checker.status {
        case let .failed(message): message
        case let .available(update): update.notes?.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "You have \(NanoAppInfo.version)."
        case let .current(date), let .noReleases(date): "Checked \(Self.relative(date))"
        case .idle, .checking: checker.lastCheckedAt.map { "Last checked \(Self.relative($0))" }
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return date.timeIntervalSinceNow > -60 ? "just now" : formatter.localizedString(for: date, relativeTo: .now)
    }
}

/// HeroUI-style switch: capsule track, white thumb, spring travel.
struct HeroSwitchToggleStyle: ToggleStyle {
    var showsLabel: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            if showsLabel {
                configuration.label
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(thumbAnimation) {
                            configuration.isOn.toggle()
                        }
                    }
                    // The switch below carries this label for VoiceOver.
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
            }
            Button {
                withAnimation(thumbAnimation) {
                    configuration.isOn.toggle()
                }
            } label: {
                Capsule()
                    .fill(configuration.isOn ? SettingsChrome.accent : Color.primary.opacity(0.18))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                            .padding(2)
                    }
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
            // A real switch for VoiceOver, named by the toggle's own label
            // (the row title), even where the label is not drawn.
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) {
                    configuration.label
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var thumbAnimation: Animation? {
        reduceMotion ? nil : .interpolatingSpring(stiffness: 380, damping: 28)
    }
}

private struct ClaudeLocalUsageRow: View {
    private enum Choice {
        case local
        case none
    }

    @ObservedObject var settings: NanoSettings
    @ObservedObject var service: AgentStatusService
    @State private var confirmingStatusInstallation = false
    @State private var choice: Choice = .none
    @State private var errorMessage: String?

    private var bridge: ClaudeStatusBridge {
        ClaudeStatusBridge(settingsURL: settings.claudeSettingsURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude usage")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Shows your 5-hour and weekly limits. Nano reads them from Claude Code's status line, or signs in with your Claude Code credentials and asks Anthropic. It stores only the percentages and reset times.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Claude usage", isOn: Binding(
                    get: { choice == .local },
                    set: { on in
                        if on { confirmingStatusInstallation = true }
                        else { apply(.none) }
                    }
                ))
                .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if choice == .local {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text(bridge.status().cachedAt.map { ClaudeLocalUsageCache.ageLabel(since: $0) }
                        ?? "Waiting for the next Claude Code response")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude configuration folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(ClaudeStatusBridge.defaultConfigDirectory.path, text: $settings.claudeConfigDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(choice == .local)
                    Text(choice == .local
                        ? "Turn Claude usage off before changing the folder."
                        : "Leave empty to use Claude Code's default, or CLAUDE_CONFIG_DIR when it's set.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("A project's own Claude settings can replace this status line.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .onAppear(perform: refreshStatus)
        .confirmationDialog("Install Claude usage status line?", isPresented: $confirmingStatusInstallation, titleVisibility: .visible) {
            Button("Install Status Line") { apply(.local) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nano adds a status line to \(bridge.settingsURL.path). If you already have one, it keeps running. Turn Claude usage off to remove Nano's.")
        }
    }

    private func apply(_ newChoice: Choice) {
        let bridge = bridge
        do {
            switch newChoice {
            case .local:
                try bridge.install()
                settings.setUsageEnabled(true, provider: .claude)
            case .none:
                try bridge.uninstall()
                settings.setUsageEnabled(false, provider: .claude)
            }
            choice = newChoice
            errorMessage = nil
            service.updateUsageProviders(settings.usageProviders)
        } catch {
            errorMessage = error.localizedDescription
            refreshStatus()
        }
    }

    private func refreshStatus() {
        let bridge = bridge
        let status = bridge.status()
        choice = status.isInstalled ? .local : .none
    }
}


/// Shows whether the call watcher is attached and the last banner it saw.
private struct CallWatcherDiagnosticsRow: View {
    @ObservedObject var watcher: IncomingCallWatcher

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(watcher.isAttached ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(watcher.isAttached ? "Watching Notification Center" : "Waiting for Accessibility")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if let last = watcher.lastSeen {
                Text("Last call: \(last.banner.caller) · \(last.banner.kind.label) · \(last.at.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No call banner seen yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
