import AppKit
import CoreAudio
import Foundation
import IOKit.ps

enum MediaPlayerKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleMusic
    case spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }
}

struct MediaNowPlaying: Equatable, Sendable {
    let player: MediaPlayerKind
    let title: String
    let artist: String
    let isPlaying: Bool
    /// Where playback was at `sampledAt`. Players only answer when asked, so
    /// views read `position(at:)` and run the clock themselves in between.
    let position: TimeInterval
    let duration: TimeInterval
    var sampledAt: Date = .now

    func position(at date: Date) -> TimeInterval {
        var value = position
        if isPlaying {
            value += max(date.timeIntervalSince(sampledAt), 0)
        }
        if duration > 0 {
            value = min(value, duration)
        }
        return max(value, 0)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return position(at: date) / duration
    }

    var progress: Double { progress(at: .now) }

    var trackID: String { "\(player.rawValue)|\(title)|\(artist)" }

    /// A new sample that agrees with the clock already running says nothing
    /// new. Publishing it would redraw every view showing the track.
    func isContinued(by sample: MediaNowPlaying) -> Bool {
        trackID == sample.trackID
            && isPlaying == sample.isPlaying
            && abs(duration - sample.duration) < 1
            && abs(position(at: sample.sampledAt) - sample.position) < 1.5
    }

    func with(isPlaying: Bool? = nil, position: TimeInterval? = nil, at date: Date = .now) -> MediaNowPlaying {
        MediaNowPlaying(
            player: player,
            title: title,
            artist: artist,
            isPlaying: isPlaying ?? self.isPlaying,
            position: position ?? self.position(at: date),
            duration: duration,
            sampledAt: date
        )
    }
}

/// The song shown, dimmed, with Resume once nothing is playing. It survives
/// restarts, so the music widget is never empty after the first song.
struct MediaLastPlayed: Codable, Equatable, Sendable {
    let player: MediaPlayerKind
    let title: String
    let artist: String
    /// The last moment it was heard playing.
    var playedAt: Date

    var trackID: String { "\(player.rawValue)|\(title)|\(artist)" }

    /// "just now", "12m ago", "2h ago", "yesterday", "3d ago".
    static func ago(from date: Date, now: Date = .now) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

/// Spotify and Music announce every play, pause, skip and seek on the
/// distributed notification center, which is what makes track changes show up
/// at once instead of on the next poll. AppKit holds distributed notifications
/// while an app is inactive, and Nano never is the active app, so these need
/// `.deliverImmediately` — only the selector-based API takes it.
private final class MediaPlayerNotificationRelay: NSObject {
    private let onChange: @MainActor @Sendable (MediaPlayerKind, Bool) -> Void

    init(onChange: @escaping @MainActor @Sendable (MediaPlayerKind, Bool) -> Void) {
        self.onChange = onChange
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(spotifyChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(musicChanged(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func spotifyChanged(_ note: Notification) {
        forward(.spotify, note)
    }

    @objc private func musicChanged(_ note: Notification) {
        forward(.appleMusic, note)
    }

    private func forward(_ player: MediaPlayerKind, _ note: Notification) {
        let isPlaying = (note.userInfo?["Player State"] as? String) == "Playing"
        let onChange = onChange
        Task { @MainActor in onChange(player, isPlaying) }
    }
}

private enum MediaRead: Sendable {
    case track(MediaNowPlaying)
    case idle
    case failed(String)
}

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var nowPlaying: MediaNowPlaying?
    @Published private(set) var availablePlayers: [MediaPlayerKind] = []
    @Published private(set) var errorMessage: String?
    @Published var preferredPlayer: MediaPlayerKind? {
        didSet {
            guard preferredPlayer != oldValue, isObserving else { return }
            refresh()
        }
    }
    @Published private(set) var artwork: NSImage?

    /// Set while macOS refuses Nano's Apple events to a player, which reads
    /// as "nothing playing" until Automation is allowed.
    var automationNote: String? {
        guard let errorMessage, errorMessage.hasPrefix(Self.automationPrefix) else { return nil }
        return errorMessage
    }

    private nonisolated static let automationPrefix = "Allow Nano to control"

    private nonisolated static func message(
        for error: MediaControlError,
        player: MediaPlayerKind
    ) -> String {
        if case .notAuthorized = error {
            return "\(automationPrefix) \(player.title) in System Settings"
        }
        return error.localizedDescription
    }

    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var playerRelay: MediaPlayerNotificationRelay?
    /// The player that most recently started playing. With no preference set,
    /// it is asked first, so a paused player never hides one that is playing.
    private var lastActivePlayer: MediaPlayerKind?
    /// Reads finish out of order when notifications arrive in bursts. Only
    /// the newest one is applied.
    private var readGeneration = 0
    private var artworkKey: String?
    /// The track whose cover already had its one retry.
    private var artworkRetriedKey: String?
    private var artworkTask: Task<Void, Never>?

    /// Apple events run here, never on the main thread. A busy or hung player
    /// holds an event until it times out, and on the main thread that froze
    /// the island with it.
    private nonisolated static let scriptQueue = DispatchQueue(
        label: "com.nanoapp.Nano.media-scripts",
        qos: .userInitiated
    )

    private var isObserving: Bool { playerRelay != nil }

    @Published private(set) var lastPlayed: MediaLastPlayed?
    /// The last song's cover, shown dimmed once nothing is playing.
    private var lastPlayedArtwork: NSImage?
    private var didLoadLastPlayed = false
    private var lastHeardAt: Date?
    private var savedLastPlayed: MediaLastPlayed?

    private nonisolated static var lastPlayedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nano/Music", isDirectory: true)
    }

    func activate() {
        loadLastPlayedIfNeeded()
        observePlayersIfNeeded()
        refresh()
    }

    func deactivate() {
        pollTimer?.invalidate()
        pollTimer = nil
        readGeneration += 1
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        playerRelay?.stop()
        playerRelay = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artwork = nil
        nowPlaying = nil
        saveLastPlayed()
    }

    func refresh() {
        pollTimer?.invalidate()
        pollTimer = nil

        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let players = MediaPlayerKind.allCases.filter {
            runningBundleIDs.contains($0.bundleIdentifier)
        }
        if availablePlayers != players {
            availablePlayers = players
        }

        readGeneration += 1
        let order = readOrder(running: players)
        guard !order.isEmpty else {
            apply(.idle)
            return
        }

        let generation = readGeneration
        Task { [weak self] in
            let read = await Self.onScriptQueue { Self.read(order) }
            guard let self, generation == self.readGeneration else { return }
            self.apply(read)
        }
    }

    /// Notifications carry changes; polling only corrects drift in the
    /// interpolated clock and catches anything a player failed to announce.
    nonisolated static func pollingInterval(
        hasRunningPlayer: Bool,
        isPlaying: Bool
    ) -> TimeInterval? {
        guard hasRunningPlayer else { return nil }
        return isPlaying ? 5 : 30
    }

    private func readOrder(running: [MediaPlayerKind]) -> [MediaPlayerKind] {
        if let preferredPlayer, running.contains(preferredPlayer) {
            return [preferredPlayer]
        }
        let lastActivePlayer = lastActivePlayer
        return running.sorted { lhs, rhs in
            lhs == lastActivePlayer && rhs != lastActivePlayer
        }
    }

    private func apply(_ read: MediaRead) {
        switch read {
        case let .track(track):
            if track.isPlaying {
                lastActivePlayer = track.player
            }
            remember(track)
            setNowPlaying(track)
            setError(nil)
        case .idle:
            setNowPlaying(nil)
            setError(nil)
        case let .failed(message):
            setNowPlaying(nil)
            setError(message)
        }
        if nowPlaying == nil {
            saveLastPlayed()
        }
        updateArtwork()
        scheduleNextRefresh()
    }

    private func scheduleNextRefresh() {
        pollTimer?.invalidate()
        guard let interval = Self.pollingInterval(
            hasRunningPlayer: !availablePlayers.isEmpty,
            isPlaying: nowPlaying?.isPlaying == true
        ) else { return }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(interval * 0.2, 3)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func observePlayersIfNeeded() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                          let bundleIdentifier = application.bundleIdentifier,
                          MediaPlayerKind.allCases.contains(where: {
                              $0.bundleIdentifier == bundleIdentifier
                          })
                    else { return }
                    Task { @MainActor in self?.refresh() }
                }
            )
        }
        playerRelay = MediaPlayerNotificationRelay { [weak self] player, isPlaying in
            guard let self else { return }
            if isPlaying {
                lastActivePlayer = player
            }
            refresh()
        }
    }

    private func setNowPlaying(_ value: MediaNowPlaying?) {
        if let current = nowPlaying, let value, current.isContinued(by: value) {
            return
        }
        guard nowPlaying != value else { return }
        nowPlaying = value
    }

    private func setError(_ value: String?) {
        guard errorMessage != value else { return }
        errorMessage = value
    }

    /// The previous cover stays up until the next one has loaded, so a skip
    /// crossfades between sleeves instead of flashing the empty one.
    private func updateArtwork() {
        guard let track = nowPlaying else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkKey = nil
            artwork = lastPlayedArtwork
            return
        }

        let key = track.trackID
        guard key != artworkKey else { return }
        artworkKey = key
        artworkTask?.cancel()

        artworkTask = Task { [weak self] in
            let data = await Self.artworkData(for: track)
            guard !Task.isCancelled, let self, self.artworkKey == key else { return }
            let image = data.flatMap(NSImage.init(data:))
            self.artwork = image
            if image == nil, self.artworkRetriedKey != key {
                // A cover can fail on a slow network or a player still
                // starting up. Forgetting the key lets the next sample try
                // once more; after that the empty sleeve stays.
                self.artworkRetriedKey = key
                self.artworkKey = nil
            }
            if self.lastPlayed?.trackID == key {
                self.lastPlayedArtwork = image
                self.saveLastPlayedArtwork(image == nil ? nil : data)
            }
        }
    }

    // MARK: Last played

    /// Polls only move `lastHeardAt`. `lastPlayed` publishes when the song
    /// changes or stops, so a playing track doesn't redraw its views each poll.
    private func remember(_ track: MediaNowPlaying) {
        guard lastPlayed?.trackID != track.trackID else {
            if track.isPlaying { lastHeardAt = .now }
            return
        }
        lastPlayed = MediaLastPlayed(
            player: track.player,
            title: track.title,
            artist: track.artist,
            playedAt: .now
        )
        lastHeardAt = track.isPlaying ? .now : nil
        // The previous song's cover must not outlive it on disk.
        lastPlayedArtwork = nil
        saveLastPlayedArtwork(nil)
        saveLastPlayed()
    }

    private func loadLastPlayedIfNeeded() {
        guard !didLoadLastPlayed else { return }
        didLoadLastPlayed = true
        let directory = Self.lastPlayedDirectory
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("last-played.json")),
              let stored = try? JSONDecoder().decode(MediaLastPlayed.self, from: data)
        else { return }
        lastPlayed = stored
        savedLastPlayed = stored
        lastPlayedArtwork = NSImage(contentsOf: directory.appendingPathComponent("last-artwork"))
        if nowPlaying == nil {
            artwork = lastPlayedArtwork
        }
    }

    private func saveLastPlayed() {
        if let lastHeardAt, var stamped = lastPlayed, stamped.playedAt != lastHeardAt {
            stamped.playedAt = lastHeardAt
            lastPlayed = stamped
        }
        guard let lastPlayed, lastPlayed != savedLastPlayed,
              let data = try? JSONEncoder().encode(lastPlayed)
        else { return }
        savedLastPlayed = lastPlayed
        let directory = Self.lastPlayedDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("last-played.json"), options: .atomic)
    }

    private func saveLastPlayedArtwork(_ data: Data?) {
        let directory = Self.lastPlayedDirectory
        let url = directory.appendingPathComponent("last-artwork")
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Plays the last song's player. An Apple event launches a closed player,
    /// and one that has only just launched can drop the first `play`, so a
    /// second follows when nothing started.
    func resumeLastPlayed() {
        guard let player = lastPlayed?.player else { return }
        lastActivePlayer = player
        let source = "tell application \"\(player.applicationName)\" to play"
        Task { [weak self] in
            _ = await Self.onScriptQueue { Self.runAppleScript(source) }
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            if nowPlaying?.isPlaying != true {
                _ = await Self.onScriptQueue { Self.runAppleScript(source) }
            }
            refresh()
        }
    }

    /// Where "Open …" points before any song has played: the preferred player
    /// when it is installed, otherwise the first one that is.
    var suggestedPlayer: MediaPlayerKind? {
        let installed = MediaPlayerKind.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
        if let preferredPlayer, installed.contains(preferredPlayer) { return preferredPlayer }
        return installed.first { $0 == .spotify } ?? installed.first
    }

    /// The player's own cover first. Music has none for many streamed and
    /// radio tracks, and Spotify none for local files; the iTunes catalog
    /// fills those in.
    private nonisolated static func artworkData(for track: MediaNowPlaying) async -> Data? {
        if let data = await playerArtworkData(for: track.player) {
            return data
        }
        return await catalogArtworkData(title: track.title, artist: track.artist)
    }

    private nonisolated static func playerArtworkData(for player: MediaPlayerKind) async -> Data? {
        switch player {
        case .spotify:
            let result = await onScriptQueue { runAppleScript(spotifyArtworkScript) }
            guard case let .success(value) = result,
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "https"
            else { return nil }
            return try? await URLSession.shared.data(from: url).0
        case .appleMusic:
            let path = NSTemporaryDirectory().appending("nano-artwork-\(UUID().uuidString).data")
            return await onScriptQueue {
                defer { try? FileManager.default.removeItem(atPath: path) }
                guard case .success = runAppleScript(appleMusicArtworkScript(path: path)) else {
                    return nil
                }
                return FileManager.default.contents(atPath: path)
            }
        }
    }

    private struct CatalogSearch: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    private nonisolated static func catalogArtworkData(title: String, artist: String) async -> Data? {
        guard !artist.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search")
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let searchURL = components.url,
              let (data, _) = try? await URLSession.shared.data(from: searchURL),
              let search = try? JSONDecoder().decode(CatalogSearch.self, from: data)
        else { return nil }

        // Exact title only. The top hit is often another song by the same
        // artist, and a wrong cover is worse than none.
        let match = search.results.first {
            $0.trackName?.localizedCaseInsensitiveCompare(title) == .orderedSame
        }
        guard let small = match?.artworkUrl100,
              let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
        else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    private nonisolated static let spotifyArtworkScript = """
    if application "Spotify" is not running then return ""
    tell application "Spotify"
        if player state is stopped then return ""
        return artwork url of current track
    end tell
    """

    private nonisolated static func appleMusicArtworkScript(path: String) -> String {
        """
        if application "Music" is not running then return ""
        tell application "Music"
            if player state is stopped then return ""
            try
                set theArtwork to raw data of artwork 1 of current track
            on error
                return ""
            end try
            set theFile to open for access POSIX file "\(path)" with write permission
            set eof theFile to 0
            write theArtwork to theFile
            close access theFile
            return "\(path)"
        end tell
        """
    }

    // MARK: Commands

    /// Flips at once; the player's own notification confirms it a moment later.
    func playPause() {
        if let track = nowPlaying {
            nowPlaying = track.with(isPlaying: !track.isPlaying)
        }
        send("playpause")
    }

    func nextTrack() {
        send("next track")
    }

    /// Music's `back track` is its own button and media key: restart the song
    /// a few seconds in, otherwise go back. Its `previous track` always skips.
    func previousTrack() {
        send(commandTarget == .appleMusic ? "back track" : "previous track")
    }

    func seek(to position: TimeInterval) {
        guard let track = nowPlaying else { return }
        let target = track.duration > 0 ? min(max(position, 0), track.duration) : max(position, 0)
        nowPlaying = track.with(position: target)
        // AppleScript source always takes a period as the decimal separator.
        send(String(format: "set player position to %.2f", target))
    }

    func openPlayer() {
        guard let player = commandTarget else { return }
        open(player)
    }

    func open(_ player: MediaPlayerKind) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    /// Commands go to the player on screen, not whichever launched first.
    private var commandTarget: MediaPlayerKind? {
        if let player = nowPlaying?.player, availablePlayers.contains(player) {
            return player
        }
        return readOrder(running: availablePlayers).first
    }

    private func send(_ command: String) {
        guard let player = commandTarget else {
            setError("Open Apple Music or Spotify first.")
            return
        }
        // Any Apple event launches its target, so a player quit a moment ago
        // would reopen without the guard.
        let name = player.applicationName
        let source = """
        if application "\(name)" is not running then return
        tell application "\(name)" to \(command)
        """
        // A read already in flight predates the command.
        readGeneration += 1
        Task { [weak self] in
            let result = await Self.onScriptQueue { Self.runAppleScript(source) }
            guard let self else { return }
            switch result {
            case .success:
                setError(nil)
            case let .failure(error):
                setError(Self.message(for: error, player: player))
            }
            refresh()
        }
    }

    // MARK: Reading

    private nonisolated static func read(_ order: [MediaPlayerKind]) -> MediaRead {
        var paused: MediaNowPlaying?
        var failure: String?
        for player in order {
            switch runAppleScript(nowPlayingScript(for: player)) {
            case let .success(value):
                guard let track = parseNowPlaying(value, player: player) else { continue }
                if track.isPlaying { return .track(track) }
                if paused == nil { paused = track }
            case let .failure(error):
                if failure == nil { failure = message(for: error, player: player) }
            }
        }
        if let paused { return .track(paused) }
        if let failure { return .failed(failure) }
        return .idle
    }

    /// Fields arrive joined by U+001F: title, artist, state, position, duration.
    /// Spotify reports duration in milliseconds, Music in seconds.
    nonisolated static func parseNowPlaying(
        _ value: String,
        player: MediaPlayerKind,
        at date: Date = .now
    ) -> MediaNowPlaying? {
        let parts = value.components(separatedBy: "\u{001F}")
        guard parts.count >= 5, parts[2] != "stopped" else { return nil }
        let rawDuration = number(parts[4])
        return MediaNowPlaying(
            player: player,
            title: parts[0].nilIfEmpty ?? "Untitled",
            artist: parts[1],
            isPlaying: parts[2] == "playing",
            position: number(parts[3]),
            duration: player == .spotify ? rawDuration / 1_000 : rawDuration,
            sampledAt: date
        )
    }

    /// AppleScript writes reals in the user's locale, so "83,52" is as likely
    /// as "83.52".
    private nonisolated static func number(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private nonisolated static func nowPlayingScript(for player: MediaPlayerKind) -> String {
        switch player {
        case .spotify:
            return """
            if application "Spotify" is not running then return "\u{001F}\u{001F}stopped\u{001F}0\u{001F}0"
            tell application "Spotify"
                if player state is stopped then return "\u{001F}\u{001F}stopped\u{001F}0\u{001F}0"
                set theTrack to current track
                return (name of theTrack as text) & "\u{001F}" & (artist of theTrack as text) & "\u{001F}" & (player state as text) & "\u{001F}" & (player position as text) & "\u{001F}" & (duration of theTrack as text)
            end tell
            """
        case .appleMusic:
            // Radio and other streams have no current track, only a stream title.
            return """
            if application "Music" is not running then return "\u{001F}\u{001F}stopped\u{001F}0\u{001F}0"
            tell application "Music"
                if player state is stopped then return "\u{001F}\u{001F}stopped\u{001F}0\u{001F}0"
                set theState to player state as text
                set thePosition to player position as text
                try
                    set theTrack to current track
                    return (name of theTrack as text) & "\u{001F}" & (artist of theTrack as text) & "\u{001F}" & theState & "\u{001F}" & thePosition & "\u{001F}" & (duration of theTrack as text)
                on error
                    set theTitle to ""
                    try
                        set theStream to current stream title
                        if theStream is not missing value then set theTitle to theStream as text
                    end try
                    return theTitle & "\u{001F}\u{001F}" & theState & "\u{001F}" & thePosition & "\u{001F}0"
                end try
            end tell
            """
        }
    }

    private nonisolated static func onScriptQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            scriptQueue.async { continuation.resume(returning: work()) }
        }
    }

    private nonisolated static func runAppleScript(_ source: String) -> Result<String, MediaControlError> {
        var details: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.invalidScript)
        }
        let result = script.executeAndReturnError(&details)
        if let details {
            // errAEEventNotPermitted and errAEEventWouldRequireUserConsent:
            // Automation is off for this player.
            if let number = details[NSAppleScript.errorNumber] as? Int, number == -1743 || number == -1744 {
                return .failure(.notAuthorized)
            }
            let message = details[NSAppleScript.errorMessage] as? String
                ?? "\(automationPrefix) the selected media player in System Settings."
            return .failure(.execution(message))
        }
        return .success(result.stringValue ?? "")
    }
}

private extension MediaPlayerKind {
    var applicationName: String {
        switch self {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        }
    }
}

private enum MediaControlError: LocalizedError, Sendable {
    case invalidScript
    case notAuthorized
    case execution(String)

    var errorDescription: String? {
        switch self {
        case .invalidScript: "Nano could not prepare the media command."
        case .notAuthorized: "Allow Nano to control the selected media player in System Settings."
        case let .execution(message): message
        }
    }
}

struct BatterySnapshot: Equatable, Sendable {
    let percentage: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let timeRemainingMinutes: Int?

    var hudSymbol: String {
        if isCharging {
            return "battery.100percent.bolt"
        }
        switch percentage {
        case ...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

@MainActor
final class SystemStatusService: ObservableObject {
    @Published private(set) var battery: BatterySnapshot?
    @Published private(set) var outputVolume: Double?
    @Published private(set) var isMuted = false
    @Published private(set) var outputMuteSettable = false

    private var timer: Timer?

    /// Reading the output volume means talking to CoreAudio, which stands up an
    /// in-process HAL client whose notification thread then services every
    /// device event on the machine — measured at 527 busy samples against the
    /// main thread's 674. Only pay for it while something is showing the value,
    /// which is the expanded island and nothing else.
    var monitorsVolume = false {
        didSet {
            guard monitorsVolume, monitorsVolume != oldValue else { return }
            refresh()
        }
    }

    func activate() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        battery = Self.readBattery()
        guard monitorsVolume else { return }
        let volume = Self.readOutputVolume()
        outputVolume = volume.level
        isMuted = volume.muted
        outputMuteSettable = Self.isOutputMuteSettable()
    }

    func setOutputVolume(_ newValue: Double) {
        guard Self.writeOutputVolume(newValue) else { return }
        outputVolume = min(max(newValue, 0), 1)
    }

    func setOutputMuted(_ muted: Bool) {
        guard Self.writeOutputMuted(muted) else { return }
        isMuted = muted
    }

    /// Desktop Macs have none, so battery alerts aren't offered there.
    static let hasBattery = readBattery() != nil

    static func readBattery() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let rawSources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }

        for rawSource in rawSources {
            guard let description = IOPSGetPowerSourceDescription(info, rawSource)?
                .takeUnretainedValue() as? [String: Any],
                // A UPS or a peripheral is a power source too. Only the Mac's own battery counts.
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description["Current Capacity"] as? Int,
                let maximum = description["Max Capacity"] as? Int,
                maximum > 0
            else {
                continue
            }

            let state = description["Power Source State"] as? String
            let time = IOPSGetTimeRemainingEstimate()
            let minutes: Int? = if time == kIOPSTimeRemainingUnknown
                || time == kIOPSTimeRemainingUnlimited
                || time < 0
            {
                nil
            } else {
                Int((time / 60).rounded())
            }

            return BatterySnapshot(
                percentage: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: description["Is Charging"] as? Bool ?? false,
                isPluggedIn: state == kIOPSACPowerValue,
                timeRemainingMinutes: minutes
            )
        }
        return nil
    }

    nonisolated static func readOutputVolume() -> (level: Double?, muted: Bool) {
        guard let deviceID = defaultOutputDevice() else { return (nil, false) }

        var volume = Float32.zero
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volumeStatus = AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )

        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(
            deviceID,
            &muteAddress,
            0,
            nil,
            &muteSize,
            &muted
        )

        return (volumeStatus == noErr ? Double(volume) : nil, muted != 0)
    }

    nonisolated static func writeOutputVolume(_ level: Double) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var value = Float32(min(max(level, 0), 1))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        ) == noErr
    }

    nonisolated static func writeOutputMuted(_ muted: Bool) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        ) == noErr
    }

    nonisolated static func isOutputMuteSettable() -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
            && settable.boolValue
    }

    nonisolated static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown
        else {
            return nil
        }
        return deviceID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
