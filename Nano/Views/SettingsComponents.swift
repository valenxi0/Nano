import SwiftUI

// MARK: - Page

/// One Settings page: a header with an icon tile, title, and a single line of
/// explanation, then its sections.
struct SettingsPage<Content: View>: View {
    var title: String
    var symbol: String?
    var subtitle: String?
    /// A link on its own line under the subtitle.
    var link: (title: String, url: URL)?
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(
        title: String = "",
        symbol: String? = nil,
        subtitle: String? = nil,
        link: (title: String, url: URL)? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.link = link
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !title.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    if let symbol {
                        SettingsIconTile(symbol: symbol, size: 34)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold))
                            .accessibilityIdentifier("settings.page.title")
                            .testProbe("settings.page.title.\(title)")
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let link {
                            Link(link.title, destination: link.url)
                                .font(.system(size: 12))
                        }
                    }
                    Spacer(minLength: 12)
                    if let trailing {
                        trailing
                    }
                }
                .padding(.bottom, 2)
            }
            content
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sections and rows

/// A titled group of rows in one rounded box, with hairlines between rows.
struct SettingsSection<Content: View>: View {
    var title: String?
    var trailing: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(
        _ title: String? = nil,
        trailing: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 2)
            }
            _VariadicView.Tree(SettingsRowStack()) {
                content
            }
            .settingsGroupBackground()
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct SettingsRowStack: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != lastID {
                    // Divider snaps to whole pixels; a 0.5pt rectangle vanishes
                    // on every other row at 1x.
                    Divider()
                        .opacity(0.55)
                        .padding(.leading, 12)
                }
            }
        }
    }
}

struct SettingsGroupBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035)))
            .overlay { shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.08), lineWidth: 0.5) }
    }
}

extension View {
    func settingsGroupBackground() -> some View {
        modifier(SettingsGroupBackground())
    }
}

/// A row: optional icon tile, a title with one line of help, and a trailing control.
struct SettingsRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    var subtitleIsWarning = false
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        symbol: String? = nil,
        subtitle: String? = nil,
        subtitleIsWarning: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.subtitleIsWarning = subtitleIsWarning
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if let symbol {
                SettingsIconTile(symbol: symbol)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(subtitleIsWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }
}

/// A row whose trailing control is a switch.
struct SettingsToggleRow: View {
    let title: String
    var symbol: String?
    var subtitle: String?
    var subtitleIsWarning = false
    @Binding var isOn: Bool

    init(
        _ title: String,
        symbol: String? = nil,
        subtitle: String? = nil,
        subtitleIsWarning: Bool = false,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.subtitleIsWarning = subtitleIsWarning
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, symbol: symbol, subtitle: subtitle, subtitleIsWarning: subtitleIsWarning) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
        }
        // One element that reads as a switch named after its row. Combining
        // the children left the switch itself without a name or a value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(subtitle ?? "")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { isOn.toggle() }
    }
}

struct SettingsIconTile: View {
    let symbol: String
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Attention strip at the top of a page, for something that blocks features.
struct SettingsBanner: View {
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
        }
    }
}

/// A small on/off capsule, for choices that sit side by side in one row.
struct SettingsChipToggle: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            // Colour alone shows the state, so a chip is the same width on or off
            // and each column stays aligned.
            // Fill only: a hairline border broke up along the pill's edge at
            // some positions, so it looked cut off.
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(isOn ? SettingsChrome.accent : Color.secondary)
                .background(
                    isOn ? SettingsChrome.accent.opacity(0.2) : Color.primary.opacity(0.07),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Cards (free-form content)

/// Free-form grouped box for content that isn't a list of rows.
struct SettingsCard<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(14)
        .settingsGroupBackground()
    }
}

struct SettingsGroupTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Notification pill previews

/// What each notification source puts on the island, drawn small enough to sit
/// in its row. A static stand-in: swap `content` for an animated capture later
/// without touching the rows.
struct NotificationPreviewPill: View {
    let source: IslandNotificationSource
    var isOn = true

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(Color.black, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
        .opacity(isOn ? 1 : 0.45)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .volume:
            Image(systemName: "speaker.wave.2.fill")
            meter(0.6)
        case .brightness:
            Image(systemName: "sun.max.fill")
            meter(0.8)
        case .bluetooth:
            Image(systemName: "airpodspro")
            Text("AirPods Pro")
            Text("84%").foregroundStyle(.white.opacity(0.55))
        case .battery:
            Image(systemName: "bolt.fill")
            Text("Charging")
            Text("41%").foregroundStyle(.white.opacity(0.55))
        case .timer:
            Image(systemName: "timer")
            Text("Focus done")
        case .agent:
            Image(systemName: "terminal.fill")
            Text("Claude finished")
        case .system:
            Image(systemName: "message.fill")
            Text("Maya: dinner at 8?")
        }
    }

    private func meter(_ value: Double) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.2))
            .frame(width: 44, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Color.white).frame(width: 44 * value, height: 4)
            }
    }
}

// MARK: - Search

/// One searchable setting: where it lives and the row to scroll to.
struct SettingsSearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let destination: SettingsDestination
    /// Row to scroll to and highlight; nil opens the page only.
    var anchor: String?

    init(_ title: String, _ detail: String, _ destination: SettingsDestination, anchor: String? = nil) {
        self.title = title
        self.detail = detail
        self.destination = destination
        self.anchor = anchor
        id = "\(destination.rawValue):\(anchor ?? title)"
    }

    @MainActor
    static func index(settings: NanoSettings) -> [SettingsSearchItem] {
        var items: [SettingsSearchItem] = [
            .init("Require a click to open", "Hovering opens the island; a click keeps it open", .general, anchor: "open.click"),
            .init("Follow the active display", "Move the island to the display you're using", .general, anchor: "open.display"),
            .init("Open at login", "Start Nano when you log in", .general, anchor: "open.login"),
            .init("Check for updates", "Update checks and the latest version", .privacy, anchor: "updates.check"),
            .init("Report a bug", "Send feedback or request a feature on GitHub", .privacy, anchor: "feedback.bug"),
            .init("Replay setup", "Walk through features and add-ons again", .general, anchor: "setup.replay"),
            .init("Shape", "Notch or Floating", .island, anchor: "island.shape"),
            .init("Surface", "Solid Black, Liquid Glass, or Hybrid", .island, anchor: "island.surface"),
            .init("Surface color", "The island's base color", .island, anchor: "island.surfaceColor"),
            .init("Glass tint", "Colors the glass and the lower edge of Hybrid", .island, anchor: "island.tint"),
            .init("Lower gradient tint", "Colors the lower edge of Hybrid", .island, anchor: "island.tint"),
            .init("Surface opacity", "Lower lets more of the wallpaper through", .island, anchor: "island.opacity"),
            .init("Glass intensity", "How strongly the glass blurs what's behind it", .island, anchor: "island.glass"),
            .init("Gradient midpoint", "Where Hybrid's black gives way to glass", .island, anchor: "island.midpoint"),
            .init("Reset appearance", "Back to the default surface", .island, anchor: "island.reset"),
            .init("Dashboard layout", "Drag features into slots, widgets, sizes", .dashboard, anchor: "dashboard.editor"),
            .init("Restore default dashboard", "Put the original layout back", .dashboard),
            .init("Replace the macOS HUD", "Media keys, volume and brightness keys go to Nano", .notifications, anchor: "notif.mediaKeys"),
            .init("Show quota as", "Used or remaining", .agents, anchor: "agents.quota"),
            .init("Live hooks", "Connect agents for approvals and questions", .agents, anchor: "agents.hooks"),
            .init("Claude usage", "Local status data for the 5h and 7d windows", .agents, anchor: "agents.claudeUsage"),
            .init("Sessions and usage", "Which agents Nano tracks", .agents, anchor: "agents.providers"),
            .init("Quill insights", "Speed, time saved, words, streak", .voiceDictation),
            .init("Quill shortcut", "Hold to talk, release to paste", .voiceDictation),
            .init("Quill engine", "Parakeet, Cohere or Whisper, on this Mac", .voiceDictation),
            .init("Dictionary", "Words and snippets for dictation", .voiceDictation),
            .init("Cue folders", "Projects and stash folders", .cue),
            .init("Cue capture shortcut", "A keyboard shortcut from any app", .cue),
            .init("Open Mixer", "Give every app its own volume", .mixer),
            .init("Mute microphone shortcut", "Mute the microphone from any app", .mixer),
            .init("Audio access", "Lets the Mixer change each app's volume", .mixer),
            .init("Version", "About Nano", .privacy, anchor: "privacy.about"),
            .init("Donate", "Tip on Ko-fi, optional", .support, anchor: "support.tip"),
            .init("Other projects", "More public repos on GitHub", .support, anchor: "support.projects"),
        ]
        for module in [NanoModuleID.music, .calendar, .weather, .timer, .camera, .tray] {
            items.append(.init(module.title, module.featureDescription, .general, anchor: "feature.\(module.rawValue)"))
        }
        // Rows that are not on screen with the current settings have nothing
        // to scroll to. Surface rows follow the chosen surface, and the media
        // keys card needs Volume or Brightness on.
        let mediaKeysShown = settings.isNotificationEnabled(.volume) || settings.isNotificationEnabled(.brightness)
        items.removeAll { item in
            switch item.anchor ?? "" {
            case "island.tint":
                // One row with two names. Keep the name the surface shows.
                return settings.appearance == .solidBlack
                    || (item.title == "Lower gradient tint") != (settings.appearance == .hybrid)
            case "island.glass":
                return settings.appearance == .solidBlack
            case "island.midpoint":
                return settings.appearance != .hybrid
            case "notif.mediaKeys":
                return !mediaKeysShown
            default:
                return false
            }
        }
        for module in [NanoModuleID.agents, .voiceDictation, .cue, .mixer] {
            items.append(.init(module.title, "Add-on: " + module.featureDescription, .general, anchor: "addon.\(module.rawValue)"))
        }
        for source in IslandNotificationSource.allCases where settings.isNotificationSourceAvailable(source) {
            // The macOS source is already called Notifications, and "Agents
            // notifications" is not how anyone says it.
            let title: String
            switch source {
            case .system: title = source.title
            case .agent: title = "Agent notifications"
            default: title = "\(source.title) notifications"
            }
            items.append(.init(title, source.subtitle, .notifications, anchor: "notif.\(source.rawValue)"))
        }
        for kind in NanoPermissionKind.allCases {
            items.append(.init("\(kind.title) permission", kind.detail, .permissions, anchor: "perm.\(kind.rawValue)"))
        }
        let available = SettingsDestination.available(settings: settings)
        return items.filter { available.contains($0.destination) }
    }

    /// Title matches first, then help-text matches.
    @MainActor
    static func search(_ query: String, settings: NanoSettings) -> [SettingsSearchItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let all = index(settings: settings)
        // Titles that start with the query, then titles with a word that
        // does, then any other title match. Order within each tier is kept.
        func rank(_ title: String) -> Int {
            let lower = title.lowercased()
            if lower.hasPrefix(needle) { return 0 }
            if lower.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 1 }
            return 2
        }
        let byTitle = all.enumerated()
            .filter { $0.element.title.lowercased().contains(needle) }
            .sorted { (rank($0.element.title), $0.offset) < (rank($1.element.title), $1.offset) }
            .map(\.element)
        let byDetail = all.filter { !$0.title.lowercased().contains(needle) && $0.detail.lowercased().contains(needle) }
        var seen = Set<String>()
        return (byTitle + byDetail).filter { seen.insert($0.id).inserted }.prefix(12).map { $0 }
    }
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row a search result pointed at, highlighted for a moment.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .id(id)
            .overlay {
                if highlight == id {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsChrome.accent.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(SettingsChrome.accent, lineWidth: 2)
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: highlight == id)
    }
}

extension View {
    /// Lets search scroll to this view and highlight it.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(id: id))
    }
}

// MARK: - Test probe

/// Where tagged controls sit, by stable ID, so window-level tests can drive
/// them with real mouse events without hard-coded coordinates. Debug builds
/// only; release builds compile the modifier away.
@MainActor
enum NanoTestProbe {
    /// Frames in the hosting view's coordinate space (top-left origin).
    static var frames: [String: CGRect] = [:]
}

extension View {
    @ViewBuilder
    func testProbe(_ id: String) -> some View {
        #if DEBUG
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { NanoTestProbe.frames[id] = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in NanoTestProbe.frames[id] = frame }
            }
        }
        #else
        self
        #endif
    }
}
