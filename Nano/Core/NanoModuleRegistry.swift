import Foundation

/// The product-facing contract for a Nano feature.
///
/// Settings, onboarding and dashboard placement all read this same registry so
/// adding a module no longer requires separate, easy-to-drift feature lists.
struct NanoModuleDescriptor: Equatable, Sendable {
    let id: NanoModuleID
    let title: String
    let dashboardTitle: String
    let symbol: String
    let description: String
    let isEnabledByDefault: Bool
    let dashboardAreas: Set<DashboardArea>
    let notificationSources: Set<IslandNotificationSource>
}

enum NanoModuleRegistry {
    private static let defaults: Set<NanoModuleID> = [
        .calendar, .timer, .camera, .weather, .agents, .music, .cue,
        .battery, .bluetooth, .volume, .brightness, .tray,
    ]

    static let modules: [NanoModuleDescriptor] = NanoModuleID.allCases.map { id in
        NanoModuleDescriptor(
            id: id,
            title: title(for: id),
            dashboardTitle: title(for: id),
            symbol: symbol(for: id),
            description: description(for: id),
            isEnabledByDefault: defaults.contains(id),
            dashboardAreas: areas(for: id),
            notificationSources: notificationSources(for: id)
        )
    }

    private static let byID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })

    static func descriptor(for id: NanoModuleID) -> NanoModuleDescriptor {
        byID[id]!
    }

    static var primaryFeatures: [NanoModuleID] {
        [.music, .weather, .agents, .cue, .tray, .calendar, .timer]
    }

    static var defaultEnabled: Set<NanoModuleID> {
        Set(modules.lazy.filter(\.isEnabledByDefault).map(\.id))
    }

    static func compatibleModules(for area: DashboardArea) -> [NanoModuleID] {
        let preferredOrder: [NanoModuleID]
        switch area {
        case .area1:
            preferredOrder = primaryFeatures
        case .area2:
            preferredOrder = [.music, .calendar, .timer, .weather, .agents]
        case .area3, .area4:
            preferredOrder = [.music, .weather, .agents, .calendar, .timer, .battery, .camera]
        case .area5, .area6:
            preferredOrder = [.camera, .timer, .agents, .weather]
        }
        return preferredOrder.filter { descriptor(for: $0).dashboardAreas.contains(area) }
    }

    /// Why `module` cannot sit in a slot of this size, phrased for Settings.
    /// Nil when it fits.
    static func unfitReason(for module: NanoModuleID, in slot: DashboardSlot) -> String? {
        guard !slots(for: module).contains(slot) else { return nil }
        switch (module, slot) {
        case (.music, .quick): return "Too small for playback controls. Media keys and the compact island cover this."
        case (.calendar, .quick): return "A date alone isn't useful here. Use a Status strip for the next event."
        case (.cue, .medium): return "The queue needs the width to keep to-dos readable."
        case (.cue, _): return "One truncated line isn't a queue. Cue needs the Wide slot."
        case (.tray, .medium): return "Needs the width for files plus the AirDrop target."
        case (.tray, _): return "Too small to drop files onto. Tray needs the Wide slot."
        case (.camera, _): return "Camera is a launcher. A live feed here would keep the camera on."
        case (.battery, _): return "Battery is one number. It fits a Status strip."
        default: return "\(descriptor(for: module).dashboardTitle) doesn't fit a \(slot.title) slot."
        }
    }

    /// Every slot size this module can be placed in.
    static func slots(for module: NanoModuleID) -> Set<DashboardSlot> {
        Set(descriptor(for: module).dashboardAreas.map(\.slot))
    }

    static func module(for source: IslandNotificationSource) -> NanoModuleID? {
        modules.first { $0.notificationSources.contains(source) }?.id
    }

    private static func areas(for id: NanoModuleID) -> Set<DashboardArea> {
        switch id {
        case .music: [.area1, .area2, .area3, .area4]
        case .weather, .agents: Set(DashboardArea.allCases)
        case .tray, .cue: [.area1]
        case .calendar: [.area1, .area2, .area3, .area4]
        case .timer: Set(DashboardArea.allCases)
        case .camera: [.area3, .area4, .area5, .area6]
        case .battery: [.area3, .area4]
        case .bluetooth, .volume, .brightness, .voiceDictation, .notificationLabs, .mixer: []
        }
    }

    private static func notificationSources(
        for id: NanoModuleID
    ) -> Set<IslandNotificationSource> {
        switch id {
        case .volume: [.volume]
        case .brightness: [.brightness]
        case .bluetooth: [.bluetooth]
        case .battery: [.battery]
        case .timer: [.timer]
        case .agents: [.agent]
        case .notificationLabs: [.system]
        default: []
        }
    }

    private static func title(for id: NanoModuleID) -> String {
        switch id {
        case .calendar: "Calendar"
        case .timer: "Timer"
        case .camera: "Camera"
        case .weather: "Weather"
        case .agents: "Agents"
        case .music: "Music"
        case .battery: "Battery"
        case .bluetooth: "Bluetooth Devices"
        case .volume: "Volume HUD"
        case .brightness: "Brightness HUD"
        case .tray: "Tray"
        case .voiceDictation: "Quill"
        case .notificationLabs: "Notifications"
        case .cue: "Cue"
        case .mixer: "Mixer"
        }
    }

    private static func symbol(for id: NanoModuleID) -> String {
        switch id {
        case .calendar: "calendar"
        case .timer: "timer"
        case .camera: "camera.fill"
        case .weather: "cloud.sun.fill"
        case .agents: "terminal.fill"
        case .music: "music.note"
        case .battery: "battery.75percent"
        case .bluetooth: "wave.3.right"
        case .volume: "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .tray: "tray.full.fill"
        case .voiceDictation: "mic.fill"
        case .notificationLabs: "bell.badge.fill"
        case .cue: "checklist"
        case .mixer: "slider.vertical.3"
        }
    }

    private static func description(for id: NanoModuleID) -> String {
        switch id {
        case .music: "Control Apple Music or Spotify from Nano."
        case .weather: "See current conditions and your local forecast."
        case .agents: "See coding agents at work, and answer them from the island."
        case .tray: "Hold files, links, and images until you drag them out, or AirDrop them."
        case .calendar: "See upcoming events from Apple Calendar."
        case .timer: "Run a focus timer with goals and breaks."
        case .camera: "Open a private camera preview."
        case .battery: "See the Mac's current battery status."
        case .bluetooth: "See supported connected Bluetooth devices."
        case .volume: "View and adjust the current output volume."
        case .brightness: "See display brightness changes."
        case .voiceDictation: "Hold a shortcut, speak, and your words land where you type."
        case .notificationLabs: "Recent macOS and Nano alerts, with reply for iMessage."
        case .cue: "Stash to-dos, prompts, and screenshots per project."
        case .mixer: "Adjust volume and mute for each app on your Mac."
        }
    }
}

@MainActor
struct NanoModuleRuntime {
    let activate: () -> Void
    let deactivate: () -> Void

    static let passive = NanoModuleRuntime(activate: {}, deactivate: {})
}

/// Runtime counterpart to `NanoModuleRegistry`. The view model composes native
/// service implementations here once, then callers activate a module without a
/// growing provider-style switch.
@MainActor
final class NanoModuleRuntimeRegistry {
    private let runtimes: [NanoModuleID: NanoModuleRuntime]

    init(runtimes: [NanoModuleID: NanoModuleRuntime]) {
        self.runtimes = runtimes
    }

    func activate(_ module: NanoModuleID) {
        (runtimes[module] ?? .passive).activate()
    }

    func deactivate(_ module: NanoModuleID?) {
        guard let module else { return }
        (runtimes[module] ?? .passive).deactivate()
    }
}
