import AppKit
import Foundation
import SwiftUI

struct NanoColorValue: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = NanoColorValue(red: 0, green: 0, blue: 0)

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = resolved.redComponent
        green = resolved.greenComponent
        blue = resolved.blueComponent
    }

    init?(components: [Double]?) {
        guard let components, components.count == 3 else { return nil }
        red = components[0]
        green = components[1]
        blue = components[2]
    }

    var components: [Double] {
        [red, green, blue]
    }
}

enum IslandPlacement: String, CaseIterable, Identifiable, Codable, Sendable {
    case attached
    case floating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attached: "Notch"
        case .floating: "Floating"
        }
    }

    var subtitle: String {
        switch self {
        case .attached: "Attached to the top edge"
        case .floating: "Floats below the top edge"
        }
    }
}

enum IslandAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case solidBlack
    case glass
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solidBlack: "Solid Black"
        case .glass: "Liquid Glass"
        case .hybrid: "Hybrid"
        }
    }
}

enum NanoModuleID: String, CaseIterable, Identifiable, Codable, Sendable {
    case calendar
    case timer
    case camera
    case weather
    case agents
    case music
    case battery
    case bluetooth
    case volume
    case brightness
    case tray
    case voiceDictation
    case notificationLabs
    case cue
    case mixer

    var id: String { rawValue }

    var title: String {
        NanoModuleRegistry.descriptor(for: self).title
    }

    var symbol: String {
        NanoModuleRegistry.descriptor(for: self).symbol
    }

    var dashboardTitle: String {
        NanoModuleRegistry.descriptor(for: self).dashboardTitle
    }

    static let primaryFeatures: [NanoModuleID] = NanoModuleRegistry.primaryFeatures

    var featureDescription: String {
        NanoModuleRegistry.descriptor(for: self).description
    }
}

enum DashboardArea: String, CaseIterable, Identifiable, Codable, Sendable {
    case area1
    case area2
    case area3
    case area4
    case area5
    case area6

    var id: String { rawValue }

    var number: Int {
        switch self {
        case .area1: 1
        case .area2: 2
        case .area3: 3
        case .area4: 4
        case .area5: 5
        case .area6: 6
        }
    }

    var title: String {
        "Area \(number)"
    }

    var role: String {
        switch self {
        case .area1: "Primary feature"
        case .area2: "Secondary feature"
        case .area3, .area4: "Status strip"
        case .area5, .area6: "Quick action"
        }
    }

    var compatibleModules: [NanoModuleID] {
        NanoModuleRegistry.compatibleModules(for: self)
    }

    var slot: DashboardSlot {
        switch self {
        case .area1: .wide
        case .area2: .medium
        case .area3, .area4: .strip
        case .area5, .area6: .quick
        }
    }
}

/// The four physical slot shapes on the dashboard.
enum DashboardSlot: String, CaseIterable, Identifiable, Sendable {
    case wide
    case medium
    case strip
    case quick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide: "Wide"
        case .medium: "Medium"
        case .strip: "Status strip"
        case .quick: "Quick action"
        }
    }

    var shortTitle: String {
        switch self {
        case .wide: "W"
        case .medium: "M"
        case .strip: "S"
        case .quick: "Q"
        }
    }
}

enum UsageDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case used
    case remaining

    var id: String { rawValue }
    var title: String { self == .used ? "Used" : "Remaining" }

    func percent(for window: NanoUsageWindow) -> Double {
        self == .used ? window.usedPercent : window.remainingPercent
    }

    func accessibilityDescription(for window: NanoUsageWindow) -> String {
        let amount = Int(percent(for: window).rounded())
        return "\(window.label) \(amount) percent \(self == .used ? "used" : "remaining")"
    }
}

enum CalendarLayout: String, CaseIterable, Sendable {
    case month
    case week

    var title: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        }
    }
}

@MainActor
final class NanoSettings: ObservableObject {
    private enum Key {
        static let placement = "island.placement"
        static let clickToOpen = "island.clickToOpen"
        static let appearance = "island.appearance"
        static let followActiveDisplay = "display.followActive"
        static let pinnedScreenID = "island.pinnedScreenID"
        static let blackOpacity = "appearance.blackOpacity"
        static let blurIntensity = "appearance.blurIntensity"
        static let gradientMidpoint = "appearance.gradientMidpoint"
        static let surfaceColor = "appearance.surfaceColor"
        static let glassTintColor = "appearance.glassTintColor"
        static let enabledModules = "modules.enabled"
        static let enabledAgentProviders = "agents.enabledProviders"
        static let weatherLocationName = "weather.locationName"
        static let weatherLatitude = "weather.latitude"
        static let weatherLongitude = "weather.longitude"
        static let weatherHasLocation = "weather.hasLocation"
        static let weatherUsesCurrentLocation = "weather.usesCurrentLocation"
        static let preferredMediaPlayer = "music.preferredPlayer"
        static let musicAnnouncesTrackChanges = "music.announcesTrackChanges"
        static let trayRemovesAfterDragOut = "tray.removesAfterDragOut"
        static let trayShowsCompactCount = "tray.showsCompactCount"
        static let checksForUpdates = "updates.checksAutomatically"
        static let hiddenCalendars = "calendar.hiddenCalendars"
        static let calendarShowsAllDay = "calendar.showsAllDay"
        static let calendarLayout = "calendar.layout"
        static let dashboardAreaAssignments = "dashboard.areaAssignments"
        static let usageProviders = "agents.usageProviders"
        static let usageDisplayMode = "agents.usageDisplayMode"
        static let claudeConfigDirectory = "agents.claudeConfigDirectory"
        static let claudeLocalUsageMigration = "agents.claudeLocalUsageMigration"
        static let trackAllSupportedMigration = "agents.trackAllSupported"
        static let trackGrokMigration = "agents.trackGrok"
        static let trackCLIBatch1bMigration = "agents.trackCLIBatch1b"
        static let trackUsageBatch1Migration = "agents.trackUsageBatch1"
        static let notificationSources = "notifications.enabledSources"
        static let timerNotificationMigration = "notifications.timerQueuedCompletionAdded"
        static let notificationModuleMigration = "modules.notificationSourceOwnersAdded"
        static let systemNotificationExcludedApps = "notifications.system.excludedApps"
        static let systemNotificationsShowBody = "notifications.system.showBody"
        static let systemNotificationsHideNativeBanner = "notifications.system.hideNativeBanner"
        static let systemNotificationsContactPhotos = "notifications.system.contactPhotos"
        static let systemNotificationsInlineReply = "notifications.system.inlineReply"
        static let systemNotificationsMarkReadAfterReply = "notifications.system.markReadAfterReply"
        static let systemNotificationsHidePreviewsOnCamera = "notifications.system.hidePreviewsOnCamera"
        static let systemNotificationsShowActions = "notifications.system.showActions"
        static let systemNotificationsCatchUp = "notifications.system.catchUp"
        static let hudReplacesSystemHUD = "hud.replaceSystem"
        static let hudReplacesVolumeKeys = "hud.replaceSystem.volume"
        static let hudReplacesBrightnessKeys = "hud.replaceSystem.brightness"
        static let hudVolumeFeedbackSound = "hud.volumeFeedbackSound"
        static let voiceDictationEngine = "voiceDictation.engine"
        static let voiceDictationActivationMode = "voiceDictation.activationMode"
        static let voiceDictationHotkey = "voiceDictation.hotkey"
        static let voiceDictationHistoryEnabled = "voiceDictation.historyEnabled"
        static let voiceDictationInsightsEnabled = "voiceDictation.insightsEnabled"
        static let voiceDictationVocabulary = "voiceDictation.vocabulary"
        static let voiceDictationCleanupLevel = "voiceDictation.cleanupLevel"
        static let voiceDictationLanguage = "voiceDictation.language"
        static let voiceDictationWritesNumbers = "voiceDictation.writesNumbers"
        static let voiceDictationFormalRegister = "voiceDictation.formalRegister"
        static let voiceDictationStructuresLists = "voiceDictation.structuresLists"
        static let voiceDictationLayoutCues = "voiceDictation.layoutCues"
        static let voiceDictationAdaptsToApp = "voiceDictation.adaptsToApp"
        static let voiceDictationLearnsCorrections = "voiceDictation.learnsCorrections"
        static let voiceDictationAppliesLearnedAutomatically = "voiceDictation.appliesLearnedAutomatically"
        static let voiceDictationLeaveOutPhrases = "voiceDictation.leaveOutPhrases"
        static let voiceDictationChangeOfMindCues = "voiceDictation.changeOfMindCues"
        static let voiceDictationSketchEnabled = "voiceDictation.sketchEnabled"
        static let voiceDictationSketchHotkey = "voiceDictation.sketchHotkey"
        static let voiceDictationSketchDrawKey = "voiceDictation.sketchDrawKey"
        static let voiceDictationFitsToCursor = "voiceDictation.fitsToCursor"
        static let voiceDictationSpokenEnter = "voiceDictation.spokenEnter"
        static let voiceDictationLivePreview = "voiceDictation.livePreview"
        static let voiceDictationAppStyles = "voiceDictation.appStyles"
        static let cueQuickCaptureEnabled = "cue.quickCaptureEnabled"
        static let cueQuickCaptureHotkey = "cue.quickCaptureHotkey"
        static let cuePullsSelection = "cue.pullsSelection"
        static let cueShowsCompactCount = "cue.showsCompactCount"
        static let mixerMicMuteHotkeyEnabled = "mixer.micMuteHotkeyEnabled"
        static let mixerMicMuteHotkey = "mixer.micMuteHotkey"
        static let cueModuleMigration = "modules.cueAdded"
        static let onboardingCompleted = "onboarding.completed"
    }

    /// Also where the timer keeps a running session, so tests that use a
    /// throwaway suite never touch the real one.
    let defaults: UserDefaults

    @Published private(set) var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    @Published var placement: IslandPlacement {
        didSet { defaults.set(placement.rawValue, forKey: Key.placement) }
    }

    /// When true, the compact island stays closed until it is clicked.
    /// Off by default: hovering the drawn notch or island opens it.
    @Published var clickToOpen: Bool {
        didSet { defaults.set(clickToOpen, forKey: Key.clickToOpen) }
    }

    @Published var appearance: IslandAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var followActiveDisplay: Bool {
        didSet { defaults.set(followActiveDisplay, forKey: Key.followActiveDisplay) }
    }

    /// The display the island stays on while "Follow the active display" is
    /// off, as its `CGDirectDisplayID`. Nil until the island has been placed.
    /// Not published: only the island panel reads and writes it, and a missing
    /// display (unplugged, or renumbered by macOS) just means placing it again.
    var pinnedScreenID: UInt32? {
        get { (defaults.object(forKey: Key.pinnedScreenID) as? NSNumber)?.uint32Value }
        set {
            if let newValue {
                defaults.set(NSNumber(value: newValue), forKey: Key.pinnedScreenID)
            } else {
                defaults.removeObject(forKey: Key.pinnedScreenID)
            }
        }
    }

    @Published var blackOpacity: Double {
        didSet { defaults.set(blackOpacity, forKey: Key.blackOpacity) }
    }

    @Published var blurIntensity: Double {
        didSet { defaults.set(blurIntensity, forKey: Key.blurIntensity) }
    }

    @Published var gradientMidpoint: Double {
        didSet { defaults.set(gradientMidpoint, forKey: Key.gradientMidpoint) }
    }

    @Published var surfaceColor: NanoColorValue {
        didSet { defaults.set(surfaceColor.components, forKey: Key.surfaceColor) }
    }

    @Published var glassTintColor: NanoColorValue {
        didSet { defaults.set(glassTintColor.components, forKey: Key.glassTintColor) }
    }

    @Published private(set) var enabledModules: Set<NanoModuleID> {
        didSet {
            defaults.set(enabledModules.map(\.rawValue).sorted(), forKey: Key.enabledModules)
        }
    }

    @Published private(set) var enabledAgentProviders: Set<AgentProviderID> {
        didSet {
            defaults.set(
                enabledAgentProviders.map(\.rawValue).sorted(),
                forKey: Key.enabledAgentProviders
            )
        }
    }

    /// Providers allowed to fetch quota. Separate from being enabled at all:
    /// token counting needs neither provider auth nor Claude's local bridge.
    @Published private(set) var usageProviders: Set<AgentProviderID> {
        didSet {
            defaults.set(usageProviders.map(\.rawValue).sorted(), forKey: Key.usageProviders)
        }
    }

    @Published var usageDisplayMode: UsageDisplayMode {
        didSet { defaults.set(usageDisplayMode.rawValue, forKey: Key.usageDisplayMode) }
    }

    /// Empty means Claude Code's standard directory, including an inherited
    /// CLAUDE_CONFIG_DIR when Nano was launched from that environment.
    @Published var claudeConfigDirectoryPath: String {
        didSet {
            let trimmed = claudeConfigDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.claudeConfigDirectory)
            } else {
                defaults.set(trimmed, forKey: Key.claudeConfigDirectory)
            }
        }
    }

    var claudeConfigDirectoryURL: URL {
        let trimmed = claudeConfigDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ClaudeStatusBridge.defaultConfigDirectory }
        return URL(
            fileURLWithPath: NSString(string: trimmed).expandingTildeInPath,
            isDirectory: true
        )
    }

    var claudeSettingsURL: URL {
        claudeConfigDirectoryURL.appendingPathComponent("settings.json")
    }

    @Published private(set) var weatherLocationName: String {
        didSet { defaults.set(weatherLocationName, forKey: Key.weatherLocationName) }
    }

    @Published private(set) var weatherLatitude: Double {
        didSet { defaults.set(weatherLatitude, forKey: Key.weatherLatitude) }
    }

    @Published private(set) var weatherLongitude: Double {
        didSet { defaults.set(weatherLongitude, forKey: Key.weatherLongitude) }
    }

    @Published var weatherUsesCurrentLocation: Bool {
        didSet { defaults.set(weatherUsesCurrentLocation, forKey: Key.weatherUsesCurrentLocation) }
    }

    @Published private(set) var weatherHasLocation: Bool {
        didSet { defaults.set(weatherHasLocation, forKey: Key.weatherHasLocation) }
    }

    /// Calendars (by title) left off the dashboard's calendar widgets.
    @Published var hiddenCalendars: Set<String> {
        didSet { defaults.set(hiddenCalendars.sorted(), forKey: Key.hiddenCalendars) }
    }

    @Published var calendarShowsAllDay: Bool {
        didSet { defaults.set(calendarShowsAllDay, forKey: Key.calendarShowsAllDay) }
    }

    /// The island's Calendar: a month and the chosen day, or a week and its timeline.
    @Published var calendarLayout: CalendarLayout {
        didSet { defaults.set(calendarLayout.rawValue, forKey: Key.calendarLayout) }
    }

    /// The dashboard's view of the calendar: hidden calendars and, when
    /// switched off, all-day events are left out.
    /// `hiddenCalendars` holds calendar identifiers. Builds before 2026-10-04
    /// stored titles, which hid every calendar sharing a name; those entries
    /// still count until the calendar is toggled.
    func isCalendarHidden(id: String, title: String) -> Bool {
        (!id.isEmpty && hiddenCalendars.contains(id)) || hiddenCalendars.contains(title)
    }

    /// `sameTitleIDs` are the other calendars with this title: showing one
    /// of them must not show the rest that a title entry was hiding.
    func setCalendarHidden(_ hidden: Bool, id: String, title: String, sameTitleIDs: [String]) {
        var next = hiddenCalendars
        if hidden {
            next.insert(id)
        } else {
            next.remove(id)
            if next.remove(title) != nil {
                next.formUnion(sameTitleIDs.filter { $0 != id })
            }
        }
        hiddenCalendars = next
    }

    func showsOnDashboard(_ event: NanoCalendarEvent) -> Bool {
        !isCalendarHidden(id: event.calendarID, title: event.calendarTitle)
            && (calendarShowsAllDay || !event.isAllDay)
    }

    @Published var preferredMediaPlayer: MediaPlayerKind? {
        didSet { defaults.set(preferredMediaPlayer?.rawValue, forKey: Key.preferredMediaPlayer) }
    }

    /// The compact island briefly widens to name a new song.
    @Published var musicAnnouncesTrackChanges: Bool {
        didSet { defaults.set(musicAnnouncesTrackChanges, forKey: Key.musicAnnouncesTrackChanges) }
    }

    /// A file dragged out of the tray leaves it. Off by default: holding is
    /// the point, and a drop the receiver refuses keeps the file either way.
    @Published var trayRemovesAfterDragOut: Bool {
        didSet { defaults.set(trayRemovesAfterDragOut, forKey: Key.trayRemovesAfterDragOut) }
    }

    /// The compact island shows how many files the tray holds.
    @Published var trayShowsCompactCount: Bool {
        didSet { defaults.set(trayShowsCompactCount, forKey: Key.trayShowsCompactCount) }
    }

    @Published var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.checksForUpdates) }
    }

    @Published private(set) var enabledNotificationSources: Set<IslandNotificationSource> {
        didSet {
            defaults.set(
                enabledNotificationSources.map(\.rawValue).sorted(),
                forKey: Key.notificationSources
            )
        }
    }

    @Published private(set) var dashboardAreaAssignments: [DashboardArea: NanoModuleID] {
        didSet {
            defaults.set(
                Dictionary(
                    uniqueKeysWithValues: dashboardAreaAssignments.map {
                        ($0.key.rawValue, $0.value.rawValue)
                    }
                ),
                forKey: Key.dashboardAreaAssignments
            )
        }
    }

    // MARK: Voice Dictation (Quill)

    @Published var voiceDictationEngine: VoiceDictationEngine {
        didSet { defaults.set(voiceDictationEngine.rawValue, forKey: Key.voiceDictationEngine) }
    }

    @Published var voiceDictationActivationMode: VoiceDictationActivationMode {
        didSet {
            defaults.set(voiceDictationActivationMode.rawValue, forKey: Key.voiceDictationActivationMode)
        }
    }

    @Published var voiceDictationHotkey: VoiceDictationHotkey {
        didSet { defaults.set(voiceDictationHotkey.storageValue, forKey: Key.voiceDictationHotkey) }
    }

    /// How S1-mini rewrites a transcript. Polished by default; only the
    /// Parakeet + S1-mini engine consults it.
    @Published var voiceDictationCleanupLevel: VoiceDictationCleanupLevel {
        didSet { defaults.set(voiceDictationCleanupLevel.rawValue, forKey: Key.voiceDictationCleanupLevel) }
    }

    /// Off by default. When on, final text is kept locally for 24 hours.
    @Published var voiceDictationHistoryEnabled: Bool {
        didSet { defaults.set(voiceDictationHistoryEnabled, forKey: Key.voiceDictationHistoryEnabled) }
    }

    /// Agents found on this Mac the last time Nano looked. Nil until the first
    /// look, which only records what's there, so setup never floods the island.
    var knownAgentInstallations: Set<AgentProviderID>? {
        get {
            (defaults.array(forKey: "agents.knownInstallations") as? [String])
                .map { Set($0.compactMap(AgentProviderID.init(rawValue:))) }
        }
        set {
            defaults.set(newValue.map { $0.map(\.rawValue).sorted() }, forKey: "agents.knownInstallations")
        }
    }

    var announcedUpdateVersion: String? {
        get { defaults.string(forKey: "updates.announcedVersion") }
        set { defaults.set(newValue, forKey: "updates.announcedVersion") }
    }

    /// On by default. Keeps counts (never text) for the Insights tab.
    @Published var voiceDictationInsightsEnabled: Bool {
        didSet { defaults.set(voiceDictationInsightsEnabled, forKey: Key.voiceDictationInsightsEnabled) }
    }

    /// `VoiceDictationLanguage.automatic` or an ISO 639-1 code. Only the
    /// multilingual engines consult it.
    @Published var voiceDictationLanguage: String {
        didSet { defaults.set(voiceDictationLanguage, forKey: Key.voiceDictationLanguage) }
    }

    /// Spoken numbers, dates and prices become figures when no cleanup model
    /// already writes them. English only.
    @Published var voiceDictationWritesNumbers: Bool {
        didSet { defaults.set(voiceDictationWritesNumbers, forKey: Key.voiceDictationWritesNumbers) }
    }

    /// Polished and Compose write contractions out ("do not").
    /// Polished turns spoken enumerations into numbered or bulleted lists.
    /// Replaces the Compose style, which was Polished with this on.
    @Published var voiceDictationStructuresLists: Bool {
        didSet { defaults.set(voiceDictationStructuresLists, forKey: Key.voiceDictationStructuresLists) }
    }

    /// "New line" and "new paragraph" break the text instead of being typed.
    @Published var voiceDictationLayoutCues: Bool {
        didSet { defaults.set(voiceDictationLayoutCues, forKey: Key.voiceDictationLayoutCues) }
    }

    /// Terminals get commands, chat apps drop a full stop, mail gets a letter layout.
    @Published var voiceDictationAdaptsToApp: Bool {
        didSet { defaults.set(voiceDictationAdaptsToApp, forKey: Key.voiceDictationAdaptsToApp) }
    }

    /// Watches the field after a paste for words the user corrects, and
    /// suggests repeated ones for the dictionary.
    @Published var voiceDictationLearnsCorrections: Bool {
        didSet { defaults.set(voiceDictationLearnsCorrections, forKey: Key.voiceDictationLearnsCorrections) }
    }

    /// Off: Nano asks about what Quill learned, at most once a day. On: it is
    /// added without asking.
    @Published var voiceDictationAppliesLearnedAutomatically: Bool {
        didSet {
            defaults.set(voiceDictationAppliesLearnedAutomatically, forKey: Key.voiceDictationAppliesLearnedAutomatically)
        }
    }

    /// Words and short phrases Quill leaves out, learned from deletions.
    @Published var voiceDictationLeaveOutPhrases: [String] {
        didSet { defaults.set(voiceDictationLeaveOutPhrases, forKey: Key.voiceDictationLeaveOutPhrases) }
    }

    /// Cues such as "actually": what came right before one is dropped when
    /// what follows restates it.
    @Published var voiceDictationChangeOfMindCues: [String] {
        didSet { defaults.set(voiceDictationChangeOfMindCues, forKey: Key.voiceDictationChangeOfMindCues) }
    }

    /// When Nano last asked about something Quill learned.
    var quillSuggestionAskedAt: Date? {
        get { defaults.object(forKey: "voiceDictation.suggestionAskedAt") as? Date }
        set { defaults.set(newValue, forKey: "voiceDictation.suggestionAskedAt") }
    }

    /// Sketch: talk while marking up the screen, then paste the screenshots
    /// and the transcript together.
    @Published var voiceDictationSketchEnabled: Bool {
        didSet { defaults.set(voiceDictationSketchEnabled, forKey: Key.voiceDictationSketchEnabled) }
    }

    @Published var voiceDictationSketchHotkey: VoiceDictationHotkey {
        didSet { defaults.set(voiceDictationSketchHotkey.storageValue, forKey: Key.voiceDictationSketchHotkey) }
    }

    /// Held while moving the pointer to draw in a Sketch.
    @Published var voiceDictationSketchDrawKey: VoiceDictationSketchDrawKey {
        didSet { defaults.set(voiceDictationSketchDrawKey.rawValue, forKey: Key.voiceDictationSketchDrawKey) }
    }

    /// Matches a dictation to the text around the cursor: lowercase in the
    /// middle of a sentence, a space where one is missing.
    @Published var voiceDictationFitsToCursor: Bool {
        didSet { defaults.set(voiceDictationFitsToCursor, forKey: Key.voiceDictationFitsToCursor) }
    }

    /// Ending a dictation with "press enter" presses Return after the paste.
    @Published var voiceDictationSpokenEnter: Bool {
        didSet { defaults.set(voiceDictationSpokenEnter, forKey: Key.voiceDictationSpokenEnter) }
    }

    /// Shows the words heard so far while recording.
    @Published var voiceDictationLivePreview: Bool {
        didSet { defaults.set(voiceDictationLivePreview, forKey: Key.voiceDictationLivePreview) }
    }

    /// A cleanup style per app, overriding `voiceDictationCleanupLevel`.
    @Published var voiceDictationAppStyles: [VoiceDictationAppStyle] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceDictationAppStyles) {
                defaults.set(data, forKey: Key.voiceDictationAppStyles)
            }
        }
    }

    /// Custom vocabulary and snippets, in the order they were added.
    @Published var voiceDictationVocabulary: [VoiceDictationVocabularyEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceDictationVocabulary) {
                defaults.set(data, forKey: Key.voiceDictationVocabulary)
            }
        }
    }

    // MARK: Cue

    @Published var cueQuickCaptureEnabled: Bool {
        didSet { defaults.set(cueQuickCaptureEnabled, forKey: Key.cueQuickCaptureEnabled) }
    }

    @Published var cueQuickCaptureHotkey: VoiceDictationHotkey {
        didSet { defaults.set(cueQuickCaptureHotkey.storageValue, forKey: Key.cueQuickCaptureHotkey) }
    }

    /// Start a capture with the text selected in the frontmost app.
    @Published var cuePullsSelection: Bool {
        didSet { defaults.set(cuePullsSelection, forKey: Key.cuePullsSelection) }
    }

    @Published var cueShowsCompactCount: Bool {
        didSet { defaults.set(cueShowsCompactCount, forKey: Key.cueShowsCompactCount) }
    }

    // MARK: Mixer

    /// Global shortcut that toggles mic mute from any app.
    @Published var mixerMicMuteHotkeyEnabled: Bool {
        didSet { defaults.set(mixerMicMuteHotkeyEnabled, forKey: Key.mixerMicMuteHotkeyEnabled) }
    }

    @Published var mixerMicMuteHotkey: VoiceDictationHotkey {
        didSet { defaults.set(mixerMicMuteHotkey.storageValue, forKey: Key.mixerMicMuteHotkey) }
    }

    /// Bundle identifiers whose macOS notifications never reach the island.
    @Published private(set) var systemNotificationExcludedApps: Set<String> {
        didSet {
            defaults.set(systemNotificationExcludedApps.sorted(), forKey: Key.systemNotificationExcludedApps)
        }
    }

    @Published var systemNotificationsShowBody: Bool {
        didSet { defaults.set(systemNotificationsShowBody, forKey: Key.systemNotificationsShowBody) }
    }

    /// Close the matching macOS banner once the island shows the same alert.
    @Published var systemNotificationsHideNativeBanner: Bool {
        didSet { defaults.set(systemNotificationsHideNativeBanner, forKey: Key.systemNotificationsHideNativeBanner) }
    }

    @Published var systemNotificationsContactPhotos: Bool {
        didSet { defaults.set(systemNotificationsContactPhotos, forKey: Key.systemNotificationsContactPhotos) }
    }

    @Published var systemNotificationsInlineReply: Bool {
        didSet { defaults.set(systemNotificationsInlineReply, forKey: Key.systemNotificationsInlineReply) }
    }

    /// After a reply from the notch, open the thread in the background so
    /// Messages clears the unread badge. Off by default: it moves a window.
    @Published var systemNotificationsMarkReadAfterReply: Bool {
        didSet { defaults.set(systemNotificationsMarkReadAfterReply, forKey: Key.systemNotificationsMarkReadAfterReply) }
    }

    /// While a camera is in use, cards show only the app name.
    @Published var systemNotificationsHidePreviewsOnCamera: Bool {
        didSet { defaults.set(systemNotificationsHidePreviewsOnCamera, forKey: Key.systemNotificationsHidePreviewsOnCamera) }
    }

    /// Show the app's own action buttons (Complete, Archive, Snooze) on the card.
    @Published var systemNotificationsShowActions: Bool {
        didSet { defaults.set(systemNotificationsShowActions, forKey: Key.systemNotificationsShowActions) }
    }

    /// One "while you were away" card after sleep or lock.
    @Published var systemNotificationsCatchUp: Bool {
        didSet { defaults.set(systemNotificationsCatchUp, forKey: Key.systemNotificationsCatchUp) }
    }

    /// Intercept the media keys so only Nano's HUD appears. Needs Accessibility.
    @Published var hudReplacesSystemHUD: Bool {
        didSet { defaults.set(hudReplacesSystemHUD, forKey: Key.hudReplacesSystemHUD) }
    }

    @Published var hudReplacesVolumeKeys: Bool {
        didSet { defaults.set(hudReplacesVolumeKeys, forKey: Key.hudReplacesVolumeKeys) }
    }

    @Published var hudReplacesBrightnessKeys: Bool {
        didSet { defaults.set(hudReplacesBrightnessKeys, forKey: Key.hudReplacesBrightnessKeys) }
    }

    /// Play the macOS volume tick after Nano applies a media-key volume change.
    @Published var hudVolumeFeedbackSound: Bool {
        didSet { defaults.set(hudVolumeFeedbackSound, forKey: Key.hudVolumeFeedbackSound) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)

        systemNotificationExcludedApps = Set(defaults.stringArray(forKey: Key.systemNotificationExcludedApps) ?? [])
        systemNotificationsShowBody = defaults.object(forKey: Key.systemNotificationsShowBody) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsShowBody)
        systemNotificationsHideNativeBanner = defaults.object(forKey: Key.systemNotificationsHideNativeBanner) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsHideNativeBanner)
        systemNotificationsContactPhotos = defaults.object(forKey: Key.systemNotificationsContactPhotos) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsContactPhotos)
        systemNotificationsInlineReply = defaults.object(forKey: Key.systemNotificationsInlineReply) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsInlineReply)
        systemNotificationsMarkReadAfterReply = defaults.bool(forKey: Key.systemNotificationsMarkReadAfterReply)
        systemNotificationsHidePreviewsOnCamera = defaults.object(forKey: Key.systemNotificationsHidePreviewsOnCamera) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsHidePreviewsOnCamera)
        systemNotificationsShowActions = defaults.object(forKey: Key.systemNotificationsShowActions) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsShowActions)
        systemNotificationsCatchUp = defaults.object(forKey: Key.systemNotificationsCatchUp) == nil
            ? true
            : defaults.bool(forKey: Key.systemNotificationsCatchUp)
        hudReplacesSystemHUD = defaults.bool(forKey: Key.hudReplacesSystemHUD)
        hudReplacesVolumeKeys = defaults.object(forKey: Key.hudReplacesVolumeKeys) == nil
            ? true
            : defaults.bool(forKey: Key.hudReplacesVolumeKeys)
        hudReplacesBrightnessKeys = defaults.object(forKey: Key.hudReplacesBrightnessKeys) == nil
            ? true
            : defaults.bool(forKey: Key.hudReplacesBrightnessKeys)
        hudVolumeFeedbackSound = defaults.bool(forKey: Key.hudVolumeFeedbackSound)

        voiceDictationEngine = defaults.string(forKey: Key.voiceDictationEngine)
            .flatMap(VoiceDictationEngine.init(rawValue:))?.offeredReplacement ?? .parakeetS1
        voiceDictationActivationMode = defaults.string(forKey: Key.voiceDictationActivationMode)
            .flatMap(VoiceDictationActivationMode.init(rawValue:)) ?? .pushToTalk
        voiceDictationHotkey = defaults.string(forKey: Key.voiceDictationHotkey)
            .flatMap(VoiceDictationHotkey.init(storageValue:)) ?? .default
        voiceDictationCleanupLevel = VoiceDictationCleanupLevel.saved(defaults.string(forKey: Key.voiceDictationCleanupLevel)) ?? .full
        voiceDictationHistoryEnabled = defaults.bool(forKey: Key.voiceDictationHistoryEnabled)
        voiceDictationInsightsEnabled = defaults.object(forKey: Key.voiceDictationInsightsEnabled) as? Bool ?? true
        voiceDictationLanguage = defaults.string(forKey: Key.voiceDictationLanguage) ?? VoiceDictationLanguage.automatic
        voiceDictationWritesNumbers = defaults.object(forKey: Key.voiceDictationWritesNumbers) as? Bool ?? true
        defaults.removeObject(forKey: "voiceDictation.holdKey")
        voiceDictationStructuresLists = defaults.object(forKey: Key.voiceDictationStructuresLists) as? Bool
            ?? (defaults.string(forKey: Key.voiceDictationCleanupLevel) == "compose")
        defaults.removeObject(forKey: Key.voiceDictationFormalRegister)
        voiceDictationLayoutCues = defaults.object(forKey: Key.voiceDictationLayoutCues) as? Bool ?? true
        voiceDictationAdaptsToApp = defaults.object(forKey: Key.voiceDictationAdaptsToApp) as? Bool ?? true
        voiceDictationLearnsCorrections = defaults.object(forKey: Key.voiceDictationLearnsCorrections) as? Bool ?? true
        voiceDictationAppliesLearnedAutomatically = defaults.object(
            forKey: Key.voiceDictationAppliesLearnedAutomatically
        ) as? Bool ?? false
        voiceDictationLeaveOutPhrases = defaults.stringArray(forKey: Key.voiceDictationLeaveOutPhrases) ?? []
        voiceDictationChangeOfMindCues = defaults.stringArray(forKey: Key.voiceDictationChangeOfMindCues) ?? []
        voiceDictationVocabulary = defaults.data(forKey: Key.voiceDictationVocabulary)
            .flatMap { try? JSONDecoder().decode([VoiceDictationVocabularyEntry].self, from: $0) } ?? []
        voiceDictationSketchEnabled = defaults.object(forKey: Key.voiceDictationSketchEnabled) as? Bool ?? true
        voiceDictationSketchHotkey = defaults.string(forKey: Key.voiceDictationSketchHotkey)
            .flatMap(VoiceDictationHotkey.init(storageValue:)) ?? .sketchDefault
        voiceDictationSketchDrawKey = defaults.string(forKey: Key.voiceDictationSketchDrawKey)
            .flatMap(VoiceDictationSketchDrawKey.init(rawValue:)) ?? .shift
        voiceDictationFitsToCursor = defaults.object(forKey: Key.voiceDictationFitsToCursor) as? Bool ?? true
        voiceDictationSpokenEnter = defaults.bool(forKey: Key.voiceDictationSpokenEnter)
        voiceDictationLivePreview = defaults.object(forKey: Key.voiceDictationLivePreview) as? Bool ?? true
        voiceDictationAppStyles = defaults.data(forKey: Key.voiceDictationAppStyles)
            .flatMap { try? JSONDecoder().decode([VoiceDictationAppStyle].self, from: $0) } ?? []
        cueQuickCaptureEnabled = defaults.object(forKey: Key.cueQuickCaptureEnabled) as? Bool ?? true
        cueQuickCaptureHotkey = defaults.string(forKey: Key.cueQuickCaptureHotkey)
            .flatMap(VoiceDictationHotkey.init(storageValue:)) ?? .cueQuickCaptureDefault
        cuePullsSelection = defaults.object(forKey: Key.cuePullsSelection) as? Bool ?? true
        cueShowsCompactCount = defaults.object(forKey: Key.cueShowsCompactCount) as? Bool ?? true
        mixerMicMuteHotkeyEnabled = defaults.object(forKey: Key.mixerMicMuteHotkeyEnabled) as? Bool ?? true
        mixerMicMuteHotkey = defaults.string(forKey: Key.mixerMicMuteHotkey)
            .flatMap(VoiceDictationHotkey.init(storageValue:)) ?? .mixerMicMuteDefault

        let hasNotch = Self.mainScreenHasNotch
        placement = defaults.string(forKey: Key.placement)
            .flatMap(IslandPlacement.init(rawValue:))
            ?? (hasNotch ? .attached : .floating)
        clickToOpen = defaults.bool(forKey: Key.clickToOpen)
        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(IslandAppearance.init(rawValue:))
            ?? (hasNotch ? .solidBlack : .hybrid)
        followActiveDisplay = defaults.object(forKey: Key.followActiveDisplay) == nil
            ? true
            : defaults.bool(forKey: Key.followActiveDisplay)
        blackOpacity = defaults.object(forKey: Key.blackOpacity) == nil
            ? 0.92
            : defaults.double(forKey: Key.blackOpacity)
        blurIntensity = defaults.object(forKey: Key.blurIntensity) == nil
            ? 0.72
            : defaults.double(forKey: Key.blurIntensity)
        gradientMidpoint = defaults.object(forKey: Key.gradientMidpoint) == nil
            ? 0.55
            : defaults.double(forKey: Key.gradientMidpoint)
        surfaceColor = NanoColorValue(
            components: defaults.array(forKey: Key.surfaceColor) as? [Double]
        ) ?? .black
        glassTintColor = NanoColorValue(
            components: defaults.array(forKey: Key.glassTintColor) as? [Double]
        ) ?? .black

        if let savedModules = defaults.stringArray(forKey: Key.enabledModules) {
            var restored = Set(savedModules.compactMap(NanoModuleID.init(rawValue:)))
            // Cue shipped after these installs chose their modules. One pass
            // turns it on; switching it off afterwards sticks.
            if !defaults.bool(forKey: Key.cueModuleMigration) {
                restored.insert(.cue)
                defaults.set(restored.map(\.rawValue).sorted(), forKey: Key.enabledModules)
            }
            enabledModules = restored
        } else {
            enabledModules = NanoModuleRegistry.defaultEnabled
        }
        defaults.set(true, forKey: Key.cueModuleMigration)

        var restoredTokens: Set<AgentProviderID>
        if let providers = defaults.stringArray(forKey: Key.enabledAgentProviders) {
            restoredTokens = Set(providers.compactMap(AgentProviderID.init(rawValue:)))
        } else {
            restoredTokens = Self.defaultTokenProviders
        }

        // Quota reads for every provider that publishes one, including Claude's
        // local status-line bridge. Token counting stays a separate switch.
        var restoredUsage: Set<AgentProviderID>
        if let stored = defaults.stringArray(forKey: Key.usageProviders) {
            restoredUsage = Set(stored.compactMap(AgentProviderID.init(rawValue:)))
        } else {
            restoredUsage = Self.defaultUsageProviders
        }

        // Older builds flipped Claude usage off to escape Keychain reads. That
        // flag is still written so the migration does not rerun, but Claude
        // stays in the default set now that the bridge no longer touches tokens.
        if !defaults.bool(forKey: Key.claudeLocalUsageMigration) {
            defaults.set(true, forKey: Key.claudeLocalUsageMigration)
        }

        // Existing installs kept Gemini/Kimi/OpenCode/Pi tokens off and Claude
        // usage off. One pass turns on every provider Nano can actually read.
        if !defaults.bool(forKey: Key.trackAllSupportedMigration) {
            restoredTokens.formUnion(Self.defaultTokenProviders)
            restoredUsage.formUnion(Self.defaultUsageProviders)
            defaults.set(true, forKey: Key.trackAllSupportedMigration)
        }
        // Existing installs already ran the all-supported pass before Grok
        // shipped. One pass turns its tokens and credits on without re-enabling
        // providers the user has since switched off.
        if !defaults.bool(forKey: Key.trackGrokMigration) {
            restoredTokens.insert(.grok)
            if AgentProviderID.grok.supportsUsage {
                restoredUsage.insert(.grok)
            }
            defaults.set(true, forKey: Key.trackGrokMigration)
        }
        // Same one-time pass for the first CLI batch (Devin, Cline, Qwen Code,
        // Kilo Code, Goose): tokens on, usage untouched — none of them publish
        // a quota Nano can read.
        if !defaults.bool(forKey: Key.trackCLIBatch1bMigration) {
            restoredTokens.formUnion([.devin, .cline, .qwen, .kilo, .goose])
            defaults.set(true, forKey: Key.trackCLIBatch1bMigration)
        }
        // Usage adapters landed after the CLI batch: one pass turns the quota
        // toggle on for Devin, Kilo, Gemini, Cline, and OpenCode without
        // re-enabling anything the user already switched off.
        if !defaults.bool(forKey: Key.trackUsageBatch1Migration) {
            restoredUsage.formUnion([.devin, .kilo, .gemini, .cline, .opencode])
            defaults.set(true, forKey: Key.trackUsageBatch1Migration)
        }
        enabledAgentProviders = restoredTokens
        usageProviders = restoredUsage
        // Property observers do not run inside init, so migrated additions
        // above would otherwise live only in memory. Persist both sets exactly
        // as their didSet does.
        defaults.set(
            restoredTokens.map(\.rawValue).sorted(),
            forKey: Key.enabledAgentProviders
        )
        defaults.set(restoredUsage.map(\.rawValue).sorted(), forKey: Key.usageProviders)
        usageDisplayMode = defaults.string(forKey: Key.usageDisplayMode)
            .flatMap(UsageDisplayMode.init(rawValue:)) ?? .used
        claudeConfigDirectoryPath = defaults.string(forKey: Key.claudeConfigDirectory) ?? ""

        weatherLocationName = defaults.string(forKey: Key.weatherLocationName) ?? ""
        weatherLatitude = defaults.double(forKey: Key.weatherLatitude)
        weatherLongitude = defaults.double(forKey: Key.weatherLongitude)
        weatherHasLocation = defaults.bool(forKey: Key.weatherHasLocation)
        weatherUsesCurrentLocation = defaults.object(forKey: Key.weatherUsesCurrentLocation) as? Bool ?? true
        hiddenCalendars = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
        calendarShowsAllDay = defaults.object(forKey: Key.calendarShowsAllDay) as? Bool ?? true
        calendarLayout = defaults.string(forKey: Key.calendarLayout).flatMap(CalendarLayout.init(rawValue:)) ?? .month
        musicAnnouncesTrackChanges = defaults.object(forKey: Key.musicAnnouncesTrackChanges) as? Bool ?? true
        trayRemovesAfterDragOut = defaults.object(forKey: Key.trayRemovesAfterDragOut) as? Bool ?? false
        trayShowsCompactCount = defaults.object(forKey: Key.trayShowsCompactCount) as? Bool ?? true
        checksForUpdates = defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true
        preferredMediaPlayer = defaults.string(forKey: Key.preferredMediaPlayer)
            .flatMap(MediaPlayerKind.init(rawValue:))

        if let savedSources = defaults.stringArray(forKey: Key.notificationSources) {
            var restored = Set(
                savedSources.compactMap(IslandNotificationSource.init(rawValue:))
            )
            // The Labs iMessage source grew into the full Notification Center
            // source. Users who opted into one already wanted the other.
            if savedSources.contains(IslandNotificationSource.legacyMessagesRawValue) {
                restored.insert(.system)
            }
            if !defaults.bool(forKey: Key.timerNotificationMigration) {
                restored.insert(.timer)
                defaults.set(true, forKey: Key.timerNotificationMigration)
            }
            enabledNotificationSources = restored
            defaults.set(
                restored.map(\.rawValue).sorted(),
                forKey: Key.notificationSources
            )
        } else {
            let defaultNotificationSources: Set<IslandNotificationSource> = [
                .volume, .brightness, .bluetooth, .battery, .timer, .agent,
            ]
            enabledNotificationSources = defaultNotificationSources
            defaults.set(true, forKey: Key.timerNotificationMigration)
            defaults.set(
                defaultNotificationSources.map(\.rawValue).sorted(),
                forKey: Key.notificationSources
            )
        }

        let defaultAreaAssignments = Self.defaultDashboardAreaAssignments
        if let savedAssignments = defaults.dictionary(forKey: Key.dashboardAreaAssignments)
            as? [String: String]
        {
            dashboardAreaAssignments = Dictionary(
                uniqueKeysWithValues: savedAssignments.compactMap { areaRawValue, moduleRawValue in
                    guard let area = DashboardArea(rawValue: areaRawValue),
                          let module = NanoModuleID(rawValue: moduleRawValue),
                          area.compatibleModules.contains(module)
                    else {
                        return nil
                    }
                    return (area, module)
                }
            )
        } else {
            dashboardAreaAssignments = defaultAreaAssignments
        }

        // System HUDs predate their General feature switches. Preserve what an
        // existing user already had enabled by turning on each source's owning
        // module once; after this, General is the master switch.
        if !defaults.bool(forKey: Key.notificationModuleMigration) {
            enabledModules.formUnion(enabledNotificationSources.compactMap {
                NanoModuleRegistry.module(for: $0)
            })
            // Same init-didSet gap as the provider sets above: persist the
            // migrated module set explicitly.
            defaults.set(
                enabledModules.map(\.rawValue).sorted(),
                forKey: Key.enabledModules
            )
            defaults.set(true, forKey: Key.notificationModuleMigration)
        }
    }

    static var defaultTokenProviders: Set<AgentProviderID> {
        Set(AgentProviderID.supported)
    }

    static var defaultUsageProviders: Set<AgentProviderID> {
        Set(AgentProviderID.supported.filter(\.supportsUsage))
    }

    func isNotificationEnabled(_ source: IslandNotificationSource) -> Bool {
        isNotificationSourceAvailable(source) && enabledNotificationSources.contains(source)
    }

    func prepareForFirstRunOnboardingOnce() {
        guard !onboardingCompleted, !defaults.bool(forKey: "onboarding.prepared") else { return }
        defaults.set(true, forKey: "onboarding.prepared")
        setEnabled(false, for: .agents)
        setEnabled(false, for: .voiceDictation)
        setNotificationEnabled(false, for: .system)
    }

    func completeOnboarding() {
        onboardingCompleted = true
        onboardingProgress = nil
    }

    var onboardingProgress: NanoOnboardingProgress? {
        get {
            defaults.data(forKey: "onboarding.progress")
                .flatMap { try? JSONDecoder().decode(NanoOnboardingProgress.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "onboarding.progress")
        }
    }

    func setSystemNotificationExcluded(_ excluded: Bool, bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if excluded {
            systemNotificationExcludedApps.insert(trimmed)
        } else {
            systemNotificationExcludedApps.remove(trimmed)
        }
        objectWillChange.send()
    }

    func isSystemNotificationExcluded(bundleID: String) -> Bool {
        systemNotificationExcludedApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func isNotificationSourceAvailable(_ source: IslandNotificationSource) -> Bool {
        switch source {
        case .system, .volume, .brightness, .bluetooth:
            return true
        case .battery:
            return SystemStatusService.hasBattery
        default:
            guard let module = NanoModuleRegistry.module(for: source) else { return true }
            return isEnabled(module)
        }
    }

    func setNotificationEnabled(_ enabled: Bool, for source: IslandNotificationSource) {
        if enabled {
            enabledNotificationSources.insert(source)
        } else {
            enabledNotificationSources.remove(source)
        }
        if let module = Self.systemNotificationModule(for: source) {
            // Battery is also a dashboard widget. Turning its alert off must
            // not take a placed widget off the dashboard.
            let keepsWidget = source == .battery && !enabled
                && dashboardAreaAssignments.values.contains(.battery)
            if !keepsWidget {
                setEnabled(enabled, for: module)
            }
        }
        objectWillChange.send()
    }

    private static func systemNotificationModule(
        for source: IslandNotificationSource
    ) -> NanoModuleID? {
        switch source {
        case .volume: .volume
        case .brightness: .brightness
        case .bluetooth: .bluetooth
        case .battery: .battery
        default: nil
        }
    }

    func isEnabled(_ module: NanoModuleID) -> Bool {
        enabledModules.contains(module)
    }

    func setEnabled(_ enabled: Bool, for module: NanoModuleID) {
        if enabled {
            enabledModules.insert(module)
        } else {
            enabledModules.remove(module)
        }
        objectWillChange.send()
    }

    func isUsageEnabled(_ provider: AgentProviderID) -> Bool {
        usageProviders.contains(provider)
    }

    func setUsageEnabled(_ enabled: Bool, provider: AgentProviderID) {
        if enabled {
            usageProviders.insert(provider)
        } else {
            usageProviders.remove(provider)
        }
        objectWillChange.send()
    }

    func isAgentProviderEnabled(_ provider: AgentProviderID) -> Bool {
        enabledAgentProviders.contains(provider)
    }

    func setAgentProviderEnabled(_ enabled: Bool, provider: AgentProviderID) {
        if enabled {
            enabledAgentProviders.insert(provider)
        } else {
            enabledAgentProviders.remove(provider)
        }
        objectWillChange.send()
    }

    func setWeatherLocation(name: String, latitude: Double, longitude: Double) {
        weatherUsesCurrentLocation = false
        weatherLocationName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        weatherLatitude = latitude
        weatherLongitude = longitude
        weatherHasLocation = true
    }

    func rememberCurrentWeatherLocation(
        name: String = "",
        latitude: Double,
        longitude: Double
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            weatherLocationName = trimmed
        }
        weatherLatitude = latitude
        weatherLongitude = longitude
        weatherHasLocation = true
    }

    func resetAppearance() {
        let hasNotch = Self.mainScreenHasNotch
        placement = hasNotch ? .attached : .floating
        appearance = hasNotch ? .solidBlack : .hybrid
        blackOpacity = 0.92
        blurIntensity = 0.72
        gradientMidpoint = 0.55
        surfaceColor = .black
        glassTintColor = .black
    }

    func dashboardFeature(in area: DashboardArea) -> NanoModuleID? {
        dashboardAreaAssignments[area]
    }

    func visibleDashboardFeature(in area: DashboardArea) -> NanoModuleID? {
        guard let module = dashboardFeature(in: area), isEnabled(module) else {
            return nil
        }
        return module
    }

    func setDashboardFeature(_ module: NanoModuleID?, in area: DashboardArea) {
        guard let module else {
            dashboardAreaAssignments.removeValue(forKey: area)
            objectWillChange.send()
            return
        }
        guard area.compatibleModules.contains(module) else { return }
        dashboardAreaAssignments[area] = module
        if !isEnabled(module) {
            setEnabled(true, for: module)
        }
        objectWillChange.send()
    }

    @discardableResult
    func moveDashboardFeature(
        _ module: NanoModuleID,
        from sourceArea: DashboardArea?,
        to destinationArea: DashboardArea
    ) -> Bool {
        guard isEnabled(module), destinationArea.compatibleModules.contains(module) else {
            return false
        }

        guard let sourceArea else {
            let displacedModule = dashboardAreaAssignments[destinationArea]
            setDashboardFeature(module, in: destinationArea)
            if let displacedModule, displacedModule != module {
                rehome(displacedModule)
                objectWillChange.send()
            }
            return true
        }
        guard sourceArea != destinationArea,
              dashboardAreaAssignments[sourceArea] == module else {
            return sourceArea == destinationArea
        }

        let displacedModule = dashboardAreaAssignments[destinationArea]
        if let displacedModule, sourceArea.compatibleModules.contains(displacedModule) {
            dashboardAreaAssignments[sourceArea] = displacedModule
        } else {
            dashboardAreaAssignments.removeValue(forKey: sourceArea)
        }
        dashboardAreaAssignments[destinationArea] = module
        if let displacedModule, displacedModule != module {
            rehome(displacedModule)
        }
        objectWillChange.send()
        return true
    }

    /// Puts a module pushed out of its slot into the first empty slot that
    /// takes it. With none free it leaves the dashboard, as before.
    private func rehome(_ module: NanoModuleID) {
        guard !dashboardAreaAssignments.values.contains(module),
              let area = DashboardArea.allCases.first(where: {
                  dashboardAreaAssignments[$0] == nil && $0.compatibleModules.contains(module)
              }) else { return }
        dashboardAreaAssignments[area] = module
    }

    func resetDashboardLayout() {
        dashboardAreaAssignments = Self.defaultDashboardAreaAssignments
        objectWillChange.send()
    }

    private static var mainScreenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    private static let defaultDashboardAreaAssignments: [DashboardArea: NanoModuleID] = [
        .area1: .music,
        .area2: .calendar,
        .area3: .weather,
        .area4: .agents,
        .area5: .camera,
        .area6: .timer,
    ]
}

struct NanoOnboardingProgress: Codable, Equatable, Sendable {
    var step: NanoOnboardingStop
    var picks: [String]
    var savedAt: Date
}

enum NanoOnboardingStop: Codable, Equatable, Sendable {
    case welcome
    case pick
    case room(OnboardingRoom)
    case summary
}
