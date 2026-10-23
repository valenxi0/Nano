import AppKit
import CoreLocation
import EventKit
import Security
import Foundation
import WeatherKit

struct NanoCalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColorHex: String
    /// From a holidays or birthdays calendar: a label on its date, never a headline.
    var isHoliday = false
    /// A Zoom, Meet, Teams, FaceTime or Webex link found on the event.
    var joinURL: URL?
    /// EventKit's identifier for the calendar. Two calendars can share a
    /// title, so hiding one is keyed on this.
    var calendarID = ""

    func overlaps(day date: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return startDate < end && endDate > start
    }
}

/// Finds the video-call link on an event, in its URL, location, or notes.
enum NanoMeetingLink {
    private static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "facetime.apple.com", "webex.com", "whereby.com", "meet.around.co",
    ]

    static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        for text in [location, notes].compactMap({ $0 }) where !text.isEmpty {
            if let found = links(in: text).first(where: isMeeting) { return found }
        }
        return nil
    }

    static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [NanoCalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let eventStore: EKEventStore
    private var storeObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var authorizationRecoveryTask: Task<Void, Never>?
    private var storeChangeTask: Task<Void, Never>?
    private var lastLoadedAt: Date?
    private var loadedDayStart: Date?
    private var browsedInterval: DateInterval?

    nonisolated private static let cacheLifetime: TimeInterval = 5 * 60

    /// Calendars the user turned off, by title. Their events are left out
    /// before the event cap, so a busy hidden calendar cannot crowd out the rest.
    var hiddenCalendarTitles: Set<String> = [] {
        didSet {
            guard hiddenCalendarTitles != oldValue, hasFullAccess, lastLoadedAt != nil else { return }
            loadUpcomingEvents()
        }
    }

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var hasFullAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// Every event calendar on this Mac, for choosing which ones show.
    var eventCalendars: [(title: String, colorHex: String, id: String)] {
        guard hasFullAccess else { return [] }
        return eventStore.calendars(for: .event)
            .map { ($0.title, Self.hexColor($0.cgColor), $0.calendarIdentifier) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func activate() {
        observeStoreIfNeeded()
        refreshAuthorization()
    }

    func refreshAuthorization(forceEventReload: Bool = false, now: Date = Date()) {
        let status = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus != status {
            authorizationStatus = status
        }
        switch status {
        case .fullAccess:
            isLoading = false
            errorMessage = nil
            observeStoreIfNeeded()
            if Self.shouldReload(
                lastLoadedAt: lastLoadedAt,
                loadedDayStart: loadedDayStart,
                now: now,
                force: forceEventReload
            ) {
                loadUpcomingEvents(now: now)
            }
        case .writeOnly:
            invalidateEventCache()
            isLoading = false
            events = []
            errorMessage = "Nano needs full Calendar access to read events."
        case .denied:
            invalidateEventCache()
            isLoading = false
            events = []
            errorMessage = "Calendar access is denied. Enable Nano in System Settings."
        case .restricted:
            invalidateEventCache()
            isLoading = false
            events = []
            errorMessage = "Calendar access is restricted on this Mac."
        case .notDetermined:
            invalidateEventCache()
            events = []
            if !isLoading {
                errorMessage = nil
            }
        @unknown default:
            invalidateEventCache()
            isLoading = false
            events = []
            errorMessage = "Calendar access is unavailable."
        }
    }

    func deactivate() {
        if storeChangeTask != nil {
            // A change was waiting to be read: make the next activation reload.
            storeChangeTask?.cancel()
            storeChangeTask = nil
            invalidateEventCache()
        }
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
            self.storeObserver = nil
        }
        if let applicationObserver {
            NotificationCenter.default.removeObserver(applicationObserver)
            self.applicationObserver = nil
        }
    }

    func requestAccess() {
        refreshAuthorization()
        switch authorizationStatus {
        case .fullAccess:
            activate()
        case .writeOnly:
            errorMessage = "Nano needs full Calendar access to read events."
        case .denied:
            errorMessage = "Calendar access is denied. Enable Nano in System Settings."
        case .restricted:
            errorMessage = "Calendar access is restricted on this Mac."
        case .notDetermined:
            requestFullAccess()
        @unknown default:
            errorMessage = "Calendar access is unavailable."
        }
    }

    private func requestFullAccess() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        authorizationRecoveryTask?.cancel()
        authorizationRecoveryTask = Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if EKEventStore.authorizationStatus(for: .event) != .notDetermined {
                    authorizationRecoveryTask = nil
                    refreshAuthorization()
                    return
                }
            }
            authorizationRecoveryTask = nil
            isLoading = false
            errorMessage = "Calendar permission did not finish. Try again."
        }
        eventStore.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAuthorization()
                if self.authorizationStatus != .notDetermined {
                    self.authorizationRecoveryTask?.cancel()
                    self.authorizationRecoveryTask = nil
                } else if let error {
                    self.authorizationRecoveryTask?.cancel()
                    self.authorizationRecoveryTask = nil
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                } else if !granted {
                    self.authorizationRecoveryTask?.cancel()
                    self.authorizationRecoveryTask = nil
                    self.isLoading = false
                    self.errorMessage = "Calendar access was not granted."
                }
            }
        }
    }

    func loadUpcomingEvents(now: Date = Date()) {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard hasFullAccess else {
            events = []
            return
        }

        isLoading = true
        errorMessage = nil

        let calendar = Calendar.current
        // From the start of this month or week, whichever is earlier, so the
        // month and week views show earlier days too.
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let start = min(monthStart, weekStart)
        let end = calendar.date(byAdding: .day, value: 62, to: today)
            ?? today.addingTimeInterval(5_356_800)
        let fetched = addingBrowsedPage(to: fetch(from: start, to: end), outside: start..<end)

        let loadedEvents = fetched.map { event in
            NanoCalendarEvent(
                // Every occurrence of a recurring event shares one identifier.
                id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
                title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled event",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar.title,
                calendarColorHex: Self.hexColor(event.calendar.cgColor),
                isHoliday: Self.isHolidayCalendar(event.calendar),
                joinURL: NanoMeetingLink.find(url: event.url, location: event.location, notes: event.notes),
                calendarID: event.calendar.calendarIdentifier
            )
        }
        if events != loadedEvents {
            events = loadedEvents
        }
        lastLoadedAt = now
        loadedDayStart = calendar.startOfDay(for: now)
        isLoading = false
    }

    func ensureEventsLoaded(for interval: DateInterval) {
        guard browsedInterval != interval else { return }
        browsedInterval = interval
        if hasFullAccess { loadUpcomingEvents() }
    }

    private func addingBrowsedPage(to upcoming: [EKEvent], outside window: Range<Date>) -> [EKEvent] {
        guard let browsedInterval,
              browsedInterval.start < window.lowerBound || browsedInterval.end > window.upperBound
        else { return upcoming }
        let occurrence = { (event: EKEvent) in "\(event.eventIdentifier ?? "")|\(event.startDate.timeIntervalSince1970)" }
        let known = Set(upcoming.map(occurrence))
        let page = fetch(from: browsedInterval.start, to: browsedInterval.end)
            .filter { !known.contains(occurrence($0)) }
        return (upcoming + page).sorted { $0.startDate < $1.startDate }
    }

    private func fetch(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let hidden = hiddenCalendarTitles
        return Array(eventStore.events(matching: predicate)
            // Entries are calendar identifiers; titles are what older builds stored.
            .filter {
                hidden.isEmpty
                    || !(hidden.contains($0.calendar.calendarIdentifier) || hidden.contains($0.calendar.title))
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(400))
    }

    nonisolated static func shouldReload(
        lastLoadedAt: Date?,
        loadedDayStart: Date?,
        now: Date,
        force: Bool
    ) -> Bool {
        guard !force, let lastLoadedAt, let loadedDayStart else { return true }
        guard Calendar.current.isDate(loadedDayStart, inSameDayAs: now) else { return true }
        return now.timeIntervalSince(lastLoadedAt) >= cacheLifetime
    }

    private func invalidateEventCache() {
        lastLoadedAt = nil
        loadedDayStart = nil
    }

    /// Everything happening on a day, including events that started earlier.
    func events(on date: Date) -> [NanoCalendarEvent] {
        events.filter { $0.overlaps(day: date) }
    }

    /// Apple's holiday calendars are read-only subscriptions; birthdays have their own type.
    private static func isHolidayCalendar(_ calendar: EKCalendar) -> Bool {
        if calendar.type == .birthday { return true }
        return calendar.type == .subscription
            && !calendar.allowsContentModifications
            && calendar.title.localizedCaseInsensitiveContains("holiday")
    }

    private func observeStoreIfNeeded() {
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleStoreReload()
                }
            }
        }
        if applicationObserver == nil {
            applicationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAuthorization()
                }
            }
        }
    }

    /// EventKit posts a burst of changes for one sync. Reload once it settles.
    private func scheduleStoreReload() {
        storeChangeTask?.cancel()
        storeChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.storeChangeTask = nil
            self?.refreshAuthorization(forceEventReload: true)
        }
    }

    private static func hexColor(_ color: CGColor) -> String {
        guard let components = color.components else { return "#FF453A" }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if components.count >= 3 {
            red = components[0]
            green = components[1]
            blue = components[2]
        } else {
            red = components[0]
            green = components[0]
            blue = components[0]
        }
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}

enum NanoWeatherSource: Sendable {
    case appleWeatherKit
    case metNorway
    case nationalWeatherService

    var attribution: String {
        switch self {
        case .appleWeatherKit: "Weather data by Apple"
        case .metNorway: "Weather data from MET Norway"
        case .nationalWeatherService: "Weather data from NOAA / NWS"
        }
    }

    var attributionURL: URL {
        switch self {
        case .appleWeatherKit:
            URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
        case .metNorway:
            URL(string: "https://api.met.no/doc/TermsOfService")!
        case .nationalWeatherService:
            URL(string: "https://www.weather.gov/documentation/services-web-api")!
        }
    }
}

struct NanoWeatherHour: Equatable, Sendable, Identifiable {
    let date: Date
    let temperature: Double
    let symbolName: String

    var id: Date { date }
}

struct NanoWeatherSnapshot: Equatable, Sendable {
    let source: NanoWeatherSource
    let placeName: String
    let temperature: Double
    let apparentTemperature: Double
    let condition: String
    let symbolName: String
    let high: Double?
    let low: Double?
    let hours: [NanoWeatherHour]
    let fetchedAt: Date
}

/// Temperatures are stored in Fahrenheit and shown in the unit the Mac's
/// region uses: Celsius unless the locale uses Fahrenheit.
enum NanoTemperature {
    /// "72°", in the locale's unit.
    static func text(_ fahrenheit: Double, locale: Locale = .current) -> String {
        let value = Measurement(value: fahrenheit, unit: UnitTemperature.fahrenheit)
            .converted(to: UnitTemperature(forLocale: locale))
            .value
            .rounded()
        // Never "-0°".
        return String(format: "%.0f°", value == 0 ? 0 : value)
    }

    /// "H 104° · L 76°"
    static func highLow(high: Double, low: Double, locale: Locale = .current) -> String {
        "H \(text(high, locale: locale)) · L \(text(low, locale: locale))"
    }
}

enum WeatherRefreshAction: Equatable, Sendable {
    case requestCurrentLocation(promptIfNeeded: Bool)
    case useSavedLocation
    case wait

    /// Launch and dashboard refreshes must not call `requestWhenInUseAuthorization`
    /// unless the user asked. Ad-hoc and rebuilt binaries get a new designated
    /// requirement, so macOS treats each launch as a first-run and would otherwise
    /// show the system prompt every time.
    static func plan(
        usesCurrentLocation: Bool,
        hasSavedLocation: Bool,
        canUseCurrentLocation: Bool,
        promptForLocation: Bool
    ) -> WeatherRefreshAction {
        if usesCurrentLocation {
            if canUseCurrentLocation {
                return .requestCurrentLocation(promptIfNeeded: false)
            }
            if promptForLocation {
                return .requestCurrentLocation(promptIfNeeded: true)
            }
            if hasSavedLocation {
                return .useSavedLocation
            }
            return .wait
        }
        return hasSavedLocation ? .useSavedLocation : .wait
    }
}

@MainActor
final class NanoWeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot: NanoWeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var onResolvedLocation: ((CLLocationCoordinate2D) -> Void)?

    private let locationManager = CLLocationManager()
    private var refreshTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var permissionPresentationTask: Task<Void, Never>?
    private var metLastModified: String?
    private var metExpires: Date?
    /// Where `snapshot` was fetched for.
    private var snapshotLocation: CLLocation?
    private var failedOffline = false
    private var wantsCurrentLocation = false
    private var awaitingLocationFix = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = locationManager.authorizationStatus
    }

    private var isStale: Bool {
        // With nothing to show, an unexpired cache header means nothing.
        guard let fetchedAt = snapshot?.fetchedAt else { return true }
        if let metExpires, Date() < metExpires { return false }
        return Date().timeIntervalSince(fetchedAt) > 600
    }

    var locationAccessIsOff: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// A few words on why there is no forecast, for surfaces too small for
    /// `errorMessage`. Nil when the reason is not known.
    var shortFailureReason: String? {
        guard snapshot == nil, errorMessage != nil else { return nil }
        if failedOffline { return "No connection" }
        if wantsCurrentLocation, locationAccessIsOff { return "Location is off" }
        return nil
    }

    /// The forecast on screen is for this place, give or take a location fix.
    private func showsForecast(for location: CLLocation) -> Bool {
        guard snapshot != nil, let snapshotLocation else { return false }
        return snapshotLocation.distance(from: location) < 5_000
    }

    /// A transient failure keeps a forecast for the same place and only marks
    /// the error. A forecast for somewhere else is dropped: it is not this one.
    private func failLoad(for location: CLLocation, error: Error?) {
        if !showsForecast(for: location) {
            snapshot = nil
            snapshotLocation = nil
        }
        failedOffline = error.map { Self.isConnectionError($0) } ?? false
        isLoading = false
        watchdogTask?.cancel()
        errorMessage = failedOffline
            ? "No internet connection. Weather updates when you are back online."
            : "Weather is unavailable right now."
    }

    nonisolated private static func isConnectionError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed, NSURLErrorTimedOut, NSURLErrorDataNotAllowed,
        ].contains(error.code)
    }

    static let hasWeatherKitEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.weatherkit" as CFString,
                  nil
              )
        else {
            return false
        }

        return (value as? Bool) ?? false
    }()

    nonisolated static func allowsCurrentLocation(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            true
        default:
            false
        }
    }

    var canUseCurrentLocation: Bool {
        Self.allowsCurrentLocation(authorizationStatus)
    }

    /// Call from a user click. Must not hop through `Task.sleep` first or
    /// macOS drops the permission sheet.
    func requestAuthorization() {
        wantsCurrentLocation = true
        authorizationStatus = locationManager.authorizationStatus
        NanoDiag.log("weather: requestAuthorization status=\(authorizationStatus.rawValue)")
        NanoActivationPolicyController.shared.beginTemporaryRegularPresentation("weather-location")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first { $0.title == "Nano Settings" }
            .map { $0.makeKeyAndOrderFront(nil) }

        switch authorizationStatus {
        case .notDetermined:
            isLoading = true
            errorMessage = nil
            // When-in-use is the Mac weather grant. Always is a no-op unless
            // Core Location considers the app "in use"; LSUIElement apps fail
            // that check even with a settings window open.
            locationManager.requestWhenInUseAuthorization()
            locationManager.requestAlwaysAuthorization()
            awaitingLocationFix = true
            locationManager.requestLocation()
            permissionPresentationTask?.cancel()
            permissionPresentationTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(20))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.finishPermissionPresentation()
            }
        case .restricted, .denied:
            isLoading = false
            errorMessage = "Location access is off. Turn it on in Privacy & Security, or set a location manually."
            finishPermissionPresentation()
        default:
            isLoading = true
            errorMessage = nil
            awaitingLocationFix = true
            locationManager.requestLocation()
            finishPermissionPresentation()
        }
    }

    func refreshCurrentLocation(force: Bool = false, promptIfNeeded: Bool = true) {
        guard force || isStale else {
            NanoDiag.log("weather: snapshot still fresh, skipping refresh")
            return
        }

        wantsCurrentLocation = true
        authorizationStatus = locationManager.authorizationStatus
        NanoDiag.log("weather: refreshCurrentLocation status=\(authorizationStatus.rawValue) prompt=\(promptIfNeeded)")
        startWatchdog()

        switch authorizationStatus {
        case .notDetermined:
            guard promptIfNeeded else {
                watchdogTask?.cancel()
                isLoading = false
                NanoDiag.log("weather: authorization undetermined, skipping automatic prompt")
                return
            }
            isLoading = true
            errorMessage = nil
            NanoDiag.log("weather: requesting authorization")
            NanoActivationPolicyController.shared.beginTemporaryRegularPresentation("weather-location")
            NSApplication.shared.activate()

            permissionPresentationTask?.cancel()
            permissionPresentationTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.locationManager.requestAlwaysAuthorization()
                do {
                    try await Task.sleep(for: .seconds(20))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.finishPermissionPresentation()
            }
        case .restricted, .denied:
            isLoading = false
            errorMessage = "Location access is off. Turn it on in Privacy & Security, or set a location manually."
        default:
            isLoading = true
            errorMessage = nil
            NanoDiag.log("weather: requesting one-shot location")
            awaitingLocationFix = true
            locationManager.requestLocation()
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.isLoading, self.snapshot == nil else { return }
            NanoDiag.log("weather: watchdog fired, still loading")
            self.isLoading = false
            self.errorMessage = self.authorizationStatus == .notDetermined
                ? "macOS never showed the location prompt. Enable Nano under Privacy & Security → Location Services, or set a location manually."
                : "Could not get a location fix. Try again, or set a location manually."
        }
    }

    func refresh(latitude: Double, longitude: Double, force: Bool = true) {
        guard force || isStale else { return }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            snapshot = nil
            errorMessage = "Enter a valid latitude and longitude."
            return
        }

        wantsCurrentLocation = false
        load(CLLocation(latitude: latitude, longitude: longitude), placeName: nil)
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        awaitingLocationFix = false
        finishPermissionPresentation()
        isLoading = false
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self, self.awaitingLocationFix else { return }
            self.awaitingLocationFix = false
            NanoDiag.log("weather: got location fix")
            self.onResolvedLocation?(location.coordinate)
            self.load(location, placeName: nil)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let description = error.localizedDescription
        Task { @MainActor [weak self] in
            NanoDiag.log("weather: location failed — \(description)")
            self?.watchdogTask?.cancel()
            self?.isLoading = false
            self?.errorMessage = "Could not read your location. \(description)"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            NanoDiag.log("weather: authorization changed to \(status.rawValue)")
            self.authorizationStatus = status
            guard self.wantsCurrentLocation, status != .notDetermined else { return }
            self.finishPermissionPresentation()
            self.refreshCurrentLocation()
        }
    }

    private func finishPermissionPresentation() {
        permissionPresentationTask?.cancel()
        permissionPresentationTask = nil
        NanoActivationPolicyController.shared.endTemporaryRegularPresentation("weather-location")
    }

    private func load(_ location: CLLocation, placeName: String?) {
        refreshTask?.cancel()
        isLoading = true
        errorMessage = nil
        failedOffline = false

        refreshTask = Task {
            guard Self.hasWeatherKitEntitlement else {
                NanoDiag.log("weather: no WeatherKit entitlement — using MET Norway")
                await loadMetNorway(location, placeName: placeName)
                return
            }

            do {
                NanoDiag.log("weather: requesting WeatherKit")
                let weather = try await WeatherKit.WeatherService.shared.weather(for: location)
                guard !Task.isCancelled else { return }
                NanoDiag.log("weather: WeatherKit responded")

                var resolvedPlace = placeName
                if resolvedPlace == nil {
                    resolvedPlace = await Self.placeName(for: location)
                }
                guard !Task.isCancelled else { return }
                let current = weather.currentWeather
                let today = weather.dailyForecast.forecast.first
                let cutoff = Date().addingTimeInterval(-1_800)
                let hours = weather.hourlyForecast.forecast
                    .filter { $0.date >= cutoff }
                    .prefix(6)
                    .map {
                        NanoWeatherHour(
                            date: $0.date,
                            temperature: $0.temperature.converted(to: .fahrenheit).value,
                            symbolName: $0.symbolName
                        )
                    }

                snapshot = NanoWeatherSnapshot(
                    source: .appleWeatherKit,
                    placeName: resolvedPlace ?? "Current Location",
                    temperature: current.temperature.converted(to: .fahrenheit).value,
                    apparentTemperature: current.apparentTemperature.converted(to: .fahrenheit).value,
                    condition: current.condition.description,
                    symbolName: current.symbolName,
                    high: today?.highTemperature.converted(to: .fahrenheit).value,
                    low: today?.lowTemperature.converted(to: .fahrenheit).value,
                    hours: Array(hours),
                    fetchedAt: Date()
                )
                snapshotLocation = location
                isLoading = false
                watchdogTask?.cancel()
            } catch is CancellationError {
                isLoading = false
            } catch {
                NanoDiag.log("weather: WeatherKit failed — \(error.localizedDescription)")
                failLoad(for: location, error: error)
            }
        }
    }

    private func loadMetNorway(_ location: CLLocation, placeName: String?) async {
        let place = await Self.place(for: location)
        let resolvedPlace = placeName ?? place.name

        if place.countryCode == "US",
           let american = await Self.nwsSnapshot(for: location, placeName: resolvedPlace) {
            guard !Task.isCancelled else { return }
            NanoDiag.log("weather: NWS responded")
            metExpires = american.expires
            snapshot = american.snapshot
            snapshotLocation = location
            isLoading = false
            watchdogTask?.cancel()
            return
        }

        // "Not modified" is only an answer when the forecast it refers to is
        // the one on screen: same request, from MET, and still there.
        let isCached = snapshot?.source == .metNorway
            && snapshotLocation.map { Self.coordinateQuery($0) } == Self.coordinateQuery(location)
        var fetched: MetResult?
        var failure: Error?
        do {
            fetched = try await Self.metSnapshot(
                for: location,
                placeName: resolvedPlace,
                lastModified: isCached ? metLastModified : nil
            )
            if let unchanged = fetched, unchanged.snapshot == nil, snapshot == nil {
                // Not modified, but nothing is cached any more: fetch it whole.
                fetched = try await Self.metSnapshot(
                    for: location,
                    placeName: resolvedPlace,
                    lastModified: nil
                )
            }
        } catch {
            failure = error
        }

        guard !Task.isCancelled else { return }
        guard let result = fetched, result.snapshot != nil || snapshot != nil else {
            failLoad(for: location, error: failure)
            return
        }

        NanoDiag.log("weather: MET Norway responded")
        metLastModified = result.lastModified
        metExpires = result.expires
        if let updated = result.snapshot {
            snapshot = updated
            snapshotLocation = location
        }
        isLoading = false
        watchdogTask?.cancel()
    }

    private typealias MetResult = (snapshot: NanoWeatherSnapshot?, lastModified: String?, expires: Date?)

    /// The coordinates as MET's query carries them.
    nonisolated private static func coordinateQuery(_ location: CLLocation) -> String {
        String(format: "%.4f,%.4f", location.coordinate.latitude, location.coordinate.longitude)
    }

    /// Throws only when the request itself fails, so the caller can tell
    /// "offline" from "the service answered with something unusable" (nil).
    private static func metSnapshot(
        for location: CLLocation,
        placeName: String,
        lastModified: String?
    ) async throws -> MetResult? {
        var components = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", location.coordinate.longitude)),
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        let modified = http.value(forHTTPHeaderField: "Last-Modified") ?? lastModified
        let expires = http.value(forHTTPHeaderField: "Expires").flatMap(httpDateFormatter.date(from:))

        guard http.statusCode != 304 else { return (nil, modified, expires) }
        guard http.statusCode == 200,
              let payload = try? metDecoder.decode(MetResponse.self, from: data)
        else {
            return nil
        }

        let series = payload.properties.timeseries
        let cutoff = Date().addingTimeInterval(-1_800)
        let upcoming = series.filter { $0.time >= cutoff }
        guard let current = upcoming.first ?? series.first else { return nil }

        let temperatures = upcoming.prefix(25).map(\.data.instant.details.airTemperature)

        let hours = upcoming
            .prefix(6)
            .map { entry in
                NanoWeatherHour(
                    date: entry.time,
                    temperature: fahrenheit(entry.data.instant.details.airTemperature),
                    symbolName: symbol(for: entry.data.next1Hours?.summary.symbolCode)
                )
            }

        return (
            NanoWeatherSnapshot(
                source: .metNorway,
                placeName: placeName,
                temperature: fahrenheit(current.data.instant.details.airTemperature),
                apparentTemperature: fahrenheit(current.data.instant.details.airTemperature),
                condition: condition(for: current.data.next1Hours?.summary.symbolCode),
                symbolName: symbol(for: current.data.next1Hours?.summary.symbolCode),
                high: temperatures.max().map(fahrenheit),
                low: temperatures.min().map(fahrenheit),
                hours: Array(hours),
                fetchedAt: Date()
            ),
            modified,
            expires
        )
    }

    private static func nwsSnapshot(
        for location: CLLocation,
        placeName: String
    ) async -> (snapshot: NanoWeatherSnapshot, expires: Date?)? {
        let pointsURL = URL(
            string: "https://api.weather.gov/points/\(String(format: "%.4f", location.coordinate.latitude)),\(String(format: "%.4f", location.coordinate.longitude))"
        )

        guard let pointsURL,
              let points = try? await fetch(NWSPoints.self, from: pointsURL),
              let hourlyURL = URL(string: points.value.properties.forecastHourly),
              let hourly = try? await fetch(NWSHourly.self, from: hourlyURL)
        else {
            return nil
        }

        let cutoff = Date().addingTimeInterval(-1_800)
        let periods = hourly.value.properties.periods.filter { $0.startTime >= cutoff }
        guard let current = periods.first else { return nil }

        let temperatures = periods.prefix(24).map { fahrenheit($0.temperature, unit: $0.temperatureUnit) }
        let hours = periods.prefix(6).map { period in
            NanoWeatherHour(
                date: period.startTime,
                temperature: fahrenheit(period.temperature, unit: period.temperatureUnit),
                symbolName: nwsSymbol(for: period.shortForecast, isDaytime: period.isDaytime)
            )
        }

        return (
            NanoWeatherSnapshot(
                source: .nationalWeatherService,
                placeName: placeName,
                temperature: fahrenheit(current.temperature, unit: current.temperatureUnit),
                apparentTemperature: fahrenheit(current.temperature, unit: current.temperatureUnit),
                condition: current.shortForecast,
                symbolName: nwsSymbol(for: current.shortForecast, isDaytime: current.isDaytime),
                high: temperatures.max(),
                low: temperatures.min(),
                hours: Array(hours),
                fetchedAt: Date()
            ),
            hourly.expires
        )
    }

    private static func fetch<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) async throws -> (value: T, expires: Date?) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let expires = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Expires")
            .flatMap(httpDateFormatter.date(from:))

        return (try metDecoder.decode(T.self, from: data), expires)
    }

    private static func fahrenheit(_ value: Double, unit: String) -> Double {
        unit.uppercased() == "C" ? value * 9 / 5 + 32 : value
    }

    private struct NWSPoints: Decodable {
        struct Properties: Decodable {
            let forecastHourly: String
        }

        let properties: Properties
    }

    private struct NWSHourly: Decodable {
        struct Period: Decodable {
            let startTime: Date
            let temperature: Double
            let temperatureUnit: String
            let shortForecast: String
            let isDaytime: Bool
        }

        struct Properties: Decodable {
            let periods: [Period]
        }

        let properties: Properties
    }

    private static func nwsSymbol(for forecast: String, isDaytime: Bool) -> String {
        let text = forecast.lowercased()

        if text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("snow") || text.contains("flurr") { return "cloud.snow.fill" }
        if text.contains("sleet") || text.contains("freezing") { return "cloud.sleet.fill" }
        if text.contains("shower") {
            return isDaytime ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        }
        if text.contains("rain") || text.contains("drizzle") { return "cloud.rain.fill" }
        if text.contains("fog") || text.contains("haze") { return "cloud.fog.fill" }
        if text.contains("mostly cloudy") || text.contains("overcast") { return "cloud.fill" }
        if text.contains("partly") || text.contains("mostly sunny") || text.contains("mostly clear") {
            return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        }
        if text.contains("cloud") { return "cloud.fill" }
        if text.contains("clear") || text.contains("sunny") || text.contains("fair") {
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        }

        return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
    }

    private static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return "Nano/\(version) (https://trynano.app; support@trynano.app)"
    }()

    private static let metDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static func fahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    private struct MetResponse: Decodable {
        struct Properties: Decodable {
            let timeseries: [Entry]
        }

        struct Entry: Decodable {
            let time: Date
            let data: EntryData
        }

        struct EntryData: Decodable {
            let instant: Instant
            let next1Hours: Period?

            enum CodingKeys: String, CodingKey {
                case instant
                case next1Hours = "next_1_hours"
            }
        }

        struct Instant: Decodable {
            let details: Details
        }

        struct Details: Decodable {
            let airTemperature: Double

            enum CodingKeys: String, CodingKey {
                case airTemperature = "air_temperature"
            }
        }

        struct Period: Decodable {
            let summary: Summary
        }

        struct Summary: Decodable {
            let symbolCode: String

            enum CodingKeys: String, CodingKey {
                case symbolCode = "symbol_code"
            }
        }

        let properties: Properties
    }

    private static func condition(for symbolCode: String?) -> String {
        switch base(of: symbolCode) {
        case "clearsky": "Clear"
        case "fair": "Fair"
        case "partlycloudy": "Partly Cloudy"
        case "cloudy": "Cloudy"
        case "fog": "Fog"
        case "lightrain", "lightrainshowers": "Light Rain"
        case "rain", "rainshowers": "Rain"
        case "heavyrain", "heavyrainshowers": "Heavy Rain"
        case "lightsleet", "sleet", "heavysleet",
             "lightsleetshowers", "sleetshowers", "heavysleetshowers": "Sleet"
        case "lightsnow", "snow", "heavysnow",
             "lightsnowshowers", "snowshowers", "heavysnowshowers": "Snow"
        default: base(of: symbolCode).contains("thunder") ? "Thunderstorms" : "Unknown"
        }
    }

    private static func symbol(for symbolCode: String?) -> String {
        let isNight = (symbolCode ?? "").hasSuffix("_night")
        let code = base(of: symbolCode)

        if code.contains("thunder") { return "cloud.bolt.rain.fill" }
        if code.contains("snow") { return "cloud.snow.fill" }
        if code.contains("sleet") { return "cloud.sleet.fill" }
        if code.contains("rain") {
            if code.contains("heavy") { return "cloud.heavyrain.fill" }
            if code.contains("showers") {
                return isNight ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill"
            }
            return "cloud.rain.fill"
        }

        switch code {
        case "clearsky": return isNight ? "moon.stars.fill" : "sun.max.fill"
        case "fair": return isNight ? "moon.stars.fill" : "sun.max.fill"
        case "partlycloudy": return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case "cloudy": return "cloud.fill"
        case "fog": return "cloud.fog.fill"
        default: return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        }
    }

    private static func base(of symbolCode: String?) -> String {
        (symbolCode ?? "").components(separatedBy: "_").first ?? ""
    }

    private static func placeName(for location: CLLocation) async -> String {
        await place(for: location).name
    }

    private static func place(for location: CLLocation) async -> (name: String, countryCode: String?) {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        let placemark = placemarks?.first
        let name = placemark?.locality
            ?? placemark?.subAdministrativeArea
            ?? placemark?.administrativeArea
            ?? "Current Location"
        return (name, placemark?.isoCountryCode)
    }
}


private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
