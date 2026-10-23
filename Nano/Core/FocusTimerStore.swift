import AppKit
import Foundation

/// A session, or the break after one. There is no Pomodoro cycle: a break is
/// offered when a session ends, never started on its own.
enum FocusTimerMode: String, CaseIterable, Identifiable, Sendable {
    case focus
    case rest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .rest: "Break"
        }
    }
}

enum FocusTimerState: String, Sendable {
    case idle
    case running
    case paused
    case completed
}

struct FocusSessionTask: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var title: String
    var isDone: Bool

    init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}

@MainActor
final class FocusTimerStore: ObservableObject {
    @Published var sessionName = "" {
        didSet { save() }
    }
    @Published private(set) var mode: FocusTimerMode = .focus {
        didSet { save() }
    }
    @Published private(set) var state: FocusTimerState = .idle {
        didSet {
            layoutDidChange?()
            save()
        }
    }
    @Published private(set) var remaining: TimeInterval = FocusTimerStore.defaultFocus
    @Published private var resetUndo: (state: FocusTimerState, remaining: TimeInterval)?
    private var resetUndoTask: Task<Void, Never>?
    @Published private(set) var configuredDuration: TimeInterval = FocusTimerStore.defaultFocus {
        didSet { save() }
    }
    /// The session's length, kept through its break so "Back to it" repeats it.
    @Published private(set) var focusDuration: TimeInterval = FocusTimerStore.defaultFocus {
        didSet { save() }
    }

    static let defaultFocus: TimeInterval = 25 * 60

    /// Five minutes after a short session, ten after about an hour, fifteen after a long one.
    static func breakLength(after focus: TimeInterval) -> TimeInterval {
        switch focus {
        case ..<(40 * 60): 5 * 60
        case ..<(80 * 60): 10 * 60
        default: 15 * 60
        }
    }

    var suggestedBreak: TimeInterval { Self.breakLength(after: focusDuration) }
    @Published private(set) var completedFocusSessions = 0 {
        didSet { save() }
    }
    @Published private(set) var tasks: [FocusSessionTask] = [] {
        didSet {
            layoutDidChange?()
            save()
        }
    }
    @Published var goalsExpanded = false {
        didSet { layoutDidChange?() }
    }

    /// Called when a running timer reaches zero, so the island can announce it.
    var didComplete: (() -> Void)?
    /// Called when something that changes the module's height changes, so the
    /// island can grow instead of clipping the goal list.
    var layoutDidChange: (() -> Void)?

    private var ticker: Timer?
    private var endDate: Date? {
        didSet { save() }
    }
    /// Where the session is kept so quitting Nano doesn't lose it. Nil keeps
    /// the timer in memory only.
    private let defaults: UserDefaults?
    private var isRestoring = false
    private static let savedKey = "timer.session"

    /// What survives a quit. A running session keeps its end time, so the
    /// time spent while Nano was closed still counts.
    private struct Saved: Codable {
        var sessionName: String
        var mode: String
        var state: String
        var endDate: Date?
        var remaining: TimeInterval
        var configuredDuration: TimeInterval
        var completedFocusSessions: Int
        var tasks: [FocusSessionTask]
        var focusDuration: TimeInterval?
    }

    init(defaults: UserDefaults? = nil, now: Date = Date()) {
        self.defaults = defaults
        restore(now: now)
    }

    /// When a running session ends.
    var endsAt: Date? {
        state == .running ? endDate : nil
    }

    /// How far into the session it is.
    var elapsed: TimeInterval {
        max(configuredDuration - remaining, 0)
    }

    /// Adding time stops at the four-hour limit.
    var canAddTime: Bool {
        configuredDuration < 14_400
    }

    var completedTaskCount: Int {
        tasks.filter(\.isDone).count
    }

    /// The goal the session is currently working toward.
    var nextTask: FocusSessionTask? {
        tasks.first { !$0.isDone }
    }

    func addTask(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks.append(FocusSessionTask(title: trimmed))
    }

    func toggleTask(_ id: FocusSessionTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isDone.toggle()
    }

    func removeTask(_ id: FocusSessionTask.ID) {
        tasks.removeAll { $0.id == id }
    }

    /// Crosses off the goal the session is on, which moves it to the next one.
    func completeCurrentTask() {
        guard let next = nextTask else { return }
        toggleTask(next.id)
    }

    /// Ends the session now, as if the time had run out, without the alert.
    func finishEarly() {
        guard state == .running || state == .paused else { return }
        stopTicker()
        endDate = nil
        remaining = 0
        if mode == .focus {
            completedFocusSessions += 1
        }
        state = .completed
    }

    /// Clears the session so the next one starts from a blank slate.
    func clearSession() {
        reset()
        if mode == .rest {
            mode = .focus
            configuredDuration = focusDuration
            remaining = configuredDuration
        }
        sessionName = ""
        tasks = []
    }

    var progress: Double {
        guard configuredDuration > 0 else { return 0 }
        return min(max(1 - (remaining / configuredDuration), 0), 1)
    }

    var formattedRemaining: String {
        let totalSeconds = max(Int(remaining.rounded(.up)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        guard hours > 0 else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    /// Starts a session of `minutes` right away, from any state.
    func startFocus(minutes: Int) {
        stopTicker()
        endDate = nil
        mode = .focus
        state = .idle
        setDuration(seconds: TimeInterval(minutes * 60))
        startOrResume()
    }

    /// After a session: a break sized to it.
    func startBreak() {
        guard mode == .focus, state == .completed else { return }
        mode = .rest
        state = .idle
        configuredDuration = suggestedBreak
        remaining = configuredDuration
        startOrResume()
    }

    /// After a session: fifteen more minutes of it.
    func keepGoing() {
        guard mode == .focus, state == .completed else { return }
        addTime(15 * 60)
        startOrResume()
    }

    /// From a break: the same session again, goals kept.
    func backToWork() {
        guard mode == .rest else { return }
        stopTicker()
        endDate = nil
        mode = .focus
        state = .idle
        configuredDuration = focusDuration
        remaining = configuredDuration
        begin()
    }

    func setDuration(seconds: TimeInterval) {
        guard state != .running else { return }
        stopTicker()
        configuredDuration = min(max(seconds.rounded(), 10), 14_400)
        remaining = configuredDuration
        state = .idle
        endDate = nil
    }

    func startOrResume() {
        // Start Timer on the setup screen is a new session: its goals start unticked.
        if mode == .focus, state == .idle, tasks.contains(where: \.isDone) {
            tasks = tasks.map { FocusSessionTask(id: $0.id, title: $0.title) }
        }
        begin()
    }

    private func begin() {
        guard state != .running else { return }
        if state == .completed || remaining <= 0 {
            remaining = configuredDuration
        }
        if mode == .focus, state == .idle {
            focusDuration = configuredDuration
        }

        state = .running
        endDate = Date().addingTimeInterval(remaining)
        startTicker()
    }

    func pause() {
        guard state == .running else { return }
        updateRemaining()
        endDate = nil
        stopTicker()
        state = .paused
    }

    /// Extends the current block. A finished block becomes paused so the
    /// extra time can be started.
    func addTime(_ seconds: TimeInterval) {
        let before = remaining
        configuredDuration = min(configuredDuration + seconds, 14_400)
        remaining = min(remaining + seconds, configuredDuration)
        if state == .running, let endDate {
            // Only what fit under the limit, so the end time matches the clock.
            self.endDate = endDate.addingTimeInterval(remaining - before)
        } else if state == .completed {
            state = .paused
        }
        save()
    }

    func reset() {
        if state != .idle {
            updateRemaining()
            resetUndo = (state, remaining)
            resetUndoTask?.cancel()
            resetUndoTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.resetUndo = nil
            }
        }
        stopTicker()
        state = .idle
        remaining = configuredDuration
        endDate = nil
    }

    /// True for a few seconds after Reset, while the session can come back.
    var canUndoReset: Bool { resetUndo != nil }

    /// Puts the session back as it was, running again if it was running.
    func undoReset() {
        guard let saved = resetUndo else { return }
        resetUndo = nil
        resetUndoTask?.cancel()
        remaining = saved.remaining
        if saved.state == .running {
            state = .paused
            begin()
        } else {
            state = saved.state
        }
        save()
    }

    private func save() {
        guard let defaults, !isRestoring else { return }
        let saved = Saved(
            sessionName: sessionName,
            mode: mode.rawValue,
            state: state.rawValue,
            endDate: endDate,
            remaining: remaining,
            configuredDuration: configuredDuration,
            completedFocusSessions: completedFocusSessions,
            tasks: tasks,
            focusDuration: focusDuration
        )
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.savedKey)
    }

    /// Picks the session back up. One that ran out while Nano was closed is
    /// shown as finished, quietly.
    private func restore(now: Date) {
        guard let data = defaults?.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        isRestoring = true
        defer { isRestoring = false }
        sessionName = saved.sessionName
        mode = FocusTimerMode(rawValue: saved.mode) ?? .focus
        configuredDuration = saved.configuredDuration
        completedFocusSessions = saved.completedFocusSessions
        tasks = saved.tasks
        focusDuration = saved.focusDuration ?? saved.configuredDuration
        switch FocusTimerState(rawValue: saved.state) ?? .idle {
        case .running:
            guard let end = saved.endDate, end > now else {
                remaining = 0
                if mode == .focus { completedFocusSessions += 1 }
                state = .completed
                return
            }
            endDate = end
            remaining = end.timeIntervalSince(now)
            state = .running
            startTicker()
        case let other:
            remaining = saved.remaining
            state = other
        }
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRemaining()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func updateRemaining() {
        guard state == .running, let endDate else { return }
        remaining = max(endDate.timeIntervalSinceNow, 0)
        guard remaining <= 0 else { return }

        stopTicker()
        self.endDate = nil
        state = .completed
        if mode == .focus {
            completedFocusSessions += 1
        }
        didComplete?()
    }
}
