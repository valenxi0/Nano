import AppKit
import CoreAudio
import Foundation

/// The moments an agent alert can sound for.
enum AgentAlertEvent: String, CaseIterable, Codable, Identifiable, Sendable {
    case approval
    case question
    case completion
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approval: "Needs approval"
        case .question: "Asks a question"
        case .completion: "Finished"
        case .usage: "Usage alert"
        }
    }

    var defaultSound: AgentAlertSound {
        switch self {
        case .approval: .system("Glass")
        case .question: .system("Ping")
        case .completion: .system("Pop")
        case .usage: .system("Hero")
        }
    }

    /// An agent's "waiting on you" notice wants the user like a question does.
    init(kind: AgentHookBridge.RequestKind) {
        switch kind {
        case .permission: self = .approval
        case .question, .notification: self = .question
        case .completion: self = .completion
        }
    }
}

/// What plays for an event. Stored as `none`, `system:<name>` or `file:<path>`.
enum AgentAlertSound: Hashable, Sendable, Codable {
    case none
    case system(String)
    case file(String)

    /// The sounds macOS ships in /System/Library/Sounds.
    static let systemNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    var title: String {
        switch self {
        case .none: "None"
        case let .system(name): name
        case let .file(path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    var storageValue: String {
        switch self {
        case .none: "none"
        case let .system(name): "system:\(name)"
        case let .file(path): "file:\(path)"
        }
    }

    init?(storageValue: String) {
        if storageValue == "none" {
            self = .none
        } else if storageValue.hasPrefix("system:") {
            let name = String(storageValue.dropFirst("system:".count))
            guard Self.systemNames.contains(name) else { return nil }
            self = .system(name)
        } else if storageValue.hasPrefix("file:") {
            let path = String(storageValue.dropFirst("file:".count))
            guard path.hasPrefix("/") else { return nil }
            self = .file(path)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let sound = Self(storageValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sound \(raw)"))
        }
        self = sound
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

/// A daily quiet window in minutes after midnight. Start after end means the
/// window runs past midnight (23:00–08:00).
struct AgentQuietSchedule: Codable, Equatable, Sendable {
    var isEnabled = false
    var startMinute = 23 * 60
    var endMinute = 8 * 60

    func contains(minute: Int) -> Bool {
        guard isEnabled, startMinute != endMinute else { return false }
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }
}

/// What the Mac is doing that should keep alerts quiet.
struct AgentQuietConditions: Equatable, Sendable {
    var screenLocked = false
    var microphoneInUse = false
}

/// Every agent alert setting, stored as one value so new fields can be added
/// without breaking what an earlier build saved.
struct AgentAlertPreferences: Codable, Equatable, Sendable {
    var soundsEnabled = true
    /// Only events the user changed are stored; the rest use their default.
    var sounds: [String: AgentAlertSound] = [:]
    var quietSchedule = AgentQuietSchedule()
    var quietWhenScreenLocked = true
    var quietWhenMicrophoneInUse = true
    var remindersEnabled = false
    var reminderMinutes = 2
    var usageAlertsEnabled = true
    /// Percent used at which a usage window is announced.
    var usageThreshold = 80
    var usageResetAlerts = true

    static let reminderChoices = [1, 2, 3, 5]
    static let usageThresholdChoices = [50, 70, 80, 90]
    static let maximumReminders = 3

    init() {}

    func sound(for event: AgentAlertEvent) -> AgentAlertSound {
        sounds[event.rawValue] ?? event.defaultSound
    }

    mutating func setSound(_ sound: AgentAlertSound, for event: AgentAlertEvent) {
        sounds[event.rawValue] = sound == event.defaultSound ? nil : sound
    }

    func isQuiet(minuteOfDay: Int, conditions: AgentQuietConditions) -> Bool {
        quietSchedule.contains(minute: minuteOfDay)
            || (quietWhenScreenLocked && conditions.screenLocked)
            || (quietWhenMicrophoneInUse && conditions.microphoneInUse)
    }

    private enum CodingKeys: String, CodingKey {
        case soundsEnabled, sounds, quietSchedule, quietWhenScreenLocked
        case quietWhenMicrophoneInUse, remindersEnabled, reminderMinutes
        case usageAlertsEnabled, usageThreshold, usageResetAlerts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentAlertPreferences()
        soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? defaults.soundsEnabled
        // One unreadable sound (a renamed system sound) must not reset the rest.
        let raw = try container.decodeIfPresent([String: String].self, forKey: .sounds) ?? [:]
        sounds = raw.compactMapValues(AgentAlertSound.init(storageValue:))
        quietSchedule = try container.decodeIfPresent(AgentQuietSchedule.self, forKey: .quietSchedule) ?? defaults.quietSchedule
        quietWhenScreenLocked = try container.decodeIfPresent(Bool.self, forKey: .quietWhenScreenLocked) ?? defaults.quietWhenScreenLocked
        quietWhenMicrophoneInUse = try container.decodeIfPresent(Bool.self, forKey: .quietWhenMicrophoneInUse) ?? defaults.quietWhenMicrophoneInUse
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? defaults.remindersEnabled
        let minutes = try container.decodeIfPresent(Int.self, forKey: .reminderMinutes) ?? defaults.reminderMinutes
        reminderMinutes = Self.reminderChoices.contains(minutes) ? minutes : defaults.reminderMinutes
        usageAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .usageAlertsEnabled) ?? defaults.usageAlertsEnabled
        let threshold = try container.decodeIfPresent(Int.self, forKey: .usageThreshold) ?? defaults.usageThreshold
        usageThreshold = Self.usageThresholdChoices.contains(threshold) ? threshold : defaults.usageThreshold
        usageResetAlerts = try container.decodeIfPresent(Bool.self, forKey: .usageResetAlerts) ?? defaults.usageResetAlerts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(soundsEnabled, forKey: .soundsEnabled)
        try container.encode(sounds.mapValues(\.storageValue), forKey: .sounds)
        try container.encode(quietSchedule, forKey: .quietSchedule)
        try container.encode(quietWhenScreenLocked, forKey: .quietWhenScreenLocked)
        try container.encode(quietWhenMicrophoneInUse, forKey: .quietWhenMicrophoneInUse)
        try container.encode(remindersEnabled, forKey: .remindersEnabled)
        try container.encode(reminderMinutes, forKey: .reminderMinutes)
        try container.encode(usageAlertsEnabled, forKey: .usageAlertsEnabled)
        try container.encode(usageThreshold, forKey: .usageThreshold)
        try container.encode(usageResetAlerts, forKey: .usageResetAlerts)
    }
}

// MARK: - Usage alerts

/// A usage window crossing the user's threshold, or coming back after it did.
struct AgentUsageAlert: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case threshold
        case reset
    }

    let kind: Kind
    let provider: AgentProviderID
    let window: NanoUsageWindow

    var key: String { AgentUsageAlertTracker.key(provider: provider, windowID: window.id) }
}

/// Decides which usage windows to announce, once per reset period.
///
/// Stored between launches so a window already announced is not announced
/// again when Nano restarts.
struct AgentUsageAlertTracker: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var alerted = false
        /// The reset time of the period that was announced, when known.
        var alertedResetsAt: Double?
        var lastUsed: Double = 0
    }

    var entries: [String: Entry] = [:]

    /// Providers report a period's end with a few seconds of drift between
    /// fetches (Codex sends seconds-until-reset); periods are hours apart.
    static let periodTolerance: TimeInterval = 15 * 60
    /// Usage this far under the threshold counts as a new period when the
    /// window has no reset time.
    static let rearmMargin: Double = 10
    /// A drop this large counts as a reset even with no reset time.
    static let resetDrop: Double = 20

    static func key(provider: AgentProviderID, windowID: String) -> String {
        "\(provider.rawValue)|\(windowID)"
    }

    mutating func evaluate(_ windows: [(AgentProviderID, NanoUsageWindow)], threshold: Double) -> [AgentUsageAlert] {
        var alerts: [AgentUsageAlert] = []
        for (provider, window) in windows {
            let key = Self.key(provider: provider, windowID: window.id)
            var entry = entries[key] ?? Entry()
            let used = window.usedPercent
            let resetsAt = window.resetsAt?.timeIntervalSince1970
            if entry.alerted {
                let periodAdvanced = resetsAt.flatMap { new in
                    entry.alertedResetsAt.map { new - $0 > Self.periodTolerance }
                } ?? false
                let dropped = used < threshold
                    && (entry.lastUsed - used >= Self.resetDrop || used < threshold - Self.rearmMargin)
                if (periodAdvanced && used < threshold) || dropped {
                    entry.alerted = false
                    entry.alertedResetsAt = nil
                    alerts.append(AgentUsageAlert(kind: .reset, provider: provider, window: window))
                } else if periodAdvanced {
                    // A new period that is already past the line.
                    entry.alertedResetsAt = resetsAt
                    alerts.append(AgentUsageAlert(kind: .threshold, provider: provider, window: window))
                }
            }
            if !entry.alerted, used >= threshold {
                entry.alerted = true
                entry.alertedResetsAt = resetsAt
                alerts.append(AgentUsageAlert(kind: .threshold, provider: provider, window: window))
            }
            entry.lastUsed = used
            entries[key] = entry
        }
        return alerts
    }
}

// MARK: - Playing and probing

@MainActor
protocol AgentSoundPlaying: AnyObject {
    func play(_ sound: AgentAlertSound)
}

@MainActor
final class SystemAgentSoundPlayer: AgentSoundPlaying {
    /// NSSound stops when released, so the one playing is kept.
    private var current: NSSound?

    func play(_ sound: AgentAlertSound) {
        let next: NSSound? = switch sound {
        case .none: nil
        case let .system(name): NSSound(named: NSSound.Name(name))
        case let .file(path): NSSound(contentsOfFile: path, byReference: true)
        }
        guard let next else { return }
        current?.stop()
        current = next
        next.play()
    }
}

protocol AgentQuietProbing: Sendable {
    func conditions() -> AgentQuietConditions
}

struct SystemAgentQuietProbe: AgentQuietProbing {
    func conditions() -> AgentQuietConditions {
        AgentQuietConditions(screenLocked: Self.screenLocked(), microphoneInUse: Self.microphoneInUseByOtherApps())
    }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Another app is recording: a call or a meeting. Nano's own Quill does
    /// not count, so dictating to an agent never silences its answer.
    static func microphoneInUseByOtherApps() -> Bool {
        let ownPID = getpid()
        return audioProcesses().contains { process in
            pid(of: process) != ownPID && isRunningInput(process)
        }
    }

    private static func audioProcesses() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

// MARK: - Alert center

/// Plays an agent alert's sound and repeats unanswered requests.
///
/// Every agent card passes through `IslandViewModel.routeNotification`, which
/// calls `didPresent`. Quiet conditions only silence sounds and reminders;
/// cards still show.
@MainActor
final class AgentAlertCenter {
    private let preferences: () -> AgentAlertPreferences
    private let isPending: (String) -> Bool
    private let represent: (IslandAgentAttention) -> Void
    private let player: AgentSoundPlaying
    private let probe: AgentQuietProbing
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private let presentUsage: (AgentUsageAlert) -> Void
    private let usageStore: UserDefaults?
    private var usageTracker: AgentUsageAlertTracker
    static let usageStateKey = "agents.usageAlertState"

    /// Requests already announced, so a card shown again (a reminder, a
    /// redelivered hook) does not sound twice.
    private var announced: [String: Date] = [:]
    private var reminders: [String: Task<Void, Never>] = [:]

    init(
        preferences: @escaping () -> AgentAlertPreferences,
        isPending: @escaping (String) -> Bool,
        represent: @escaping (IslandAgentAttention) -> Void,
        player: AgentSoundPlaying = SystemAgentSoundPlayer(),
        probe: AgentQuietProbing = SystemAgentQuietProbe(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        presentUsage: @escaping (AgentUsageAlert) -> Void = { _ in },
        usageStore: UserDefaults? = .standard
    ) {
        self.preferences = preferences
        self.isPending = isPending
        self.represent = represent
        self.player = player
        self.probe = probe
        self.now = now
        self.sleep = sleep
        self.presentUsage = presentUsage
        self.usageStore = usageStore
        usageTracker = usageStore?.data(forKey: Self.usageStateKey)
            .flatMap { try? JSONDecoder().decode(AgentUsageAlertTracker.self, from: $0) }
            ?? AgentUsageAlertTracker()
    }

    /// Called after a usage refresh. Announces windows past the threshold
    /// and, if wanted, windows that reset after being announced.
    func usageDidRefresh(_ snapshots: [AgentProviderSnapshot]) {
        let preferences = preferences()
        guard preferences.usageAlertsEnabled else { return }
        let windows = snapshots
            .filter { $0.isConfigured && $0.hasQuota }
            .flatMap { snapshot in snapshot.usage.map { (snapshot.id, $0) } }
        let alerts = usageTracker.evaluate(windows, threshold: Double(preferences.usageThreshold))
            .filter { $0.kind == .threshold || preferences.usageResetAlerts }
        if let data = try? JSONEncoder().encode(usageTracker) {
            usageStore?.set(data, forKey: Self.usageStateKey)
        }
        guard !alerts.isEmpty else { return }
        alerts.forEach(presentUsage)
        play(.usage)
    }

    func didPresent(_ attention: IslandAgentAttention) {
        prune()
        guard announced[attention.requestID] == nil else { return }
        announced[attention.requestID] = now()
        play(AgentAlertEvent(kind: attention.kind))
        scheduleReminder(for: attention, attempt: 1)
    }

    /// Plays the event's sound unless sounds are off or it is quiet now.
    func play(_ event: AgentAlertEvent) {
        let preferences = preferences()
        guard preferences.soundsEnabled, !isQuiet(preferences) else { return }
        player.play(preferences.sound(for: event))
    }

    /// Settings preview: plays regardless of quiet conditions.
    func preview(_ sound: AgentAlertSound) {
        player.play(sound)
    }

    func isQuiet(_ preferences: AgentAlertPreferences? = nil) -> Bool {
        let preferences = preferences ?? self.preferences()
        let components = Calendar.current.dateComponents([.hour, .minute], from: now())
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return preferences.isQuiet(minuteOfDay: minute, conditions: probe.conditions())
    }

    private func scheduleReminder(for attention: IslandAgentAttention, attempt: Int) {
        let preferences = preferences()
        guard preferences.remindersEnabled,
              attention.kind == .permission || attention.kind == .question,
              attempt <= AgentAlertPreferences.maximumReminders
        else { return }
        let id = attention.requestID
        let delay = TimeInterval(preferences.reminderMinutes * 60)
        reminders[id]?.cancel()
        reminders[id] = Task { [weak self] in
            await self?.sleep(delay)
            guard !Task.isCancelled else { return }
            self?.remind(attention, attempt: attempt)
        }
    }

    private func remind(_ attention: IslandAgentAttention, attempt: Int) {
        let id = attention.requestID
        reminders[id] = nil
        // Answered, denied, or the agent moved on: nothing to remind about.
        guard preferences().remindersEnabled, isPending(id) else { return }
        // Quiet skips this reminder but keeps the next, so one still comes
        // once the meeting or the night is over.
        if !isQuiet() {
            represent(attention)
            play(AgentAlertEvent(kind: attention.kind))
        }
        scheduleReminder(for: attention, attempt: attempt + 1)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-3600)
        announced = announced.filter { $0.value > cutoff }
    }
}
