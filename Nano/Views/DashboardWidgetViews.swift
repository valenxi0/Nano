import AppKit
import SwiftUI

// MARK: - Collapsing layout

/// Where each filled area goes when some are empty. Empty areas draw nothing:
/// neighbours in the same row take their space, and a row with nothing in it
/// collapses so the island gets shorter.
enum DashboardLayout {
    struct Placement: Equatable {
        let frame: CGRect
        /// The size the widget renders at. A Medium feature alone on the top
        /// row uses its Wide layout rather than a stretched Medium one.
        let slot: DashboardSlot
        /// A quick action given enough room shows its name beside its icon.
        let widensQuick: Bool
    }

    static let spacing: CGFloat = 8
    static let stripHeight: CGFloat = 54
    /// 300pt of dashboard island less the inset above and below.
    static let fullHeight: CGFloat = 272
    static var topHeight: CGFloat { fullHeight - stripHeight - spacing }
    /// Height of the "Set up dashboard" state when every area is empty.
    static let emptyHeight: CGFloat = 120
    /// Space between the dashboard and the island's edge, the same on every side.
    static let inset: CGFloat = 14

    @MainActor
    static func filledAreas(_ settings: NanoSettings) -> Set<DashboardArea> {
        Set(DashboardArea.allCases.filter { settings.visibleDashboardFeature(in: $0) != nil })
    }

    static func contentHeight(filled: Set<DashboardArea>) -> CGFloat {
        let top = filled.contains(.area1) || filled.contains(.area2)
        let bottom = !filled.isDisjoint(with: [.area3, .area4, .area5, .area6])
        switch (top, bottom) {
        case (true, true): return fullHeight
        case (true, false): return topHeight
        case (false, true): return stripHeight
        case (false, false): return emptyHeight
        }
    }

    /// The uncollapsed frames: every area in its place.
    static func frames(in size: CGSize) -> [DashboardArea: CGRect] {
        let rightWidth = max(210, size.width * 0.29)
        let leftWidth = max(size.width - rightWidth - spacing, 0)
        let topHeight = max(size.height - stripHeight - spacing, 0)
        let halfLeft = (leftWidth - spacing) / 2
        let halfRight = (rightWidth - spacing) / 2
        let bottomY = topHeight + spacing
        let rightX = leftWidth + spacing
        return [
            .area1: CGRect(x: 0, y: 0, width: leftWidth, height: topHeight),
            .area2: CGRect(x: rightX, y: 0, width: rightWidth, height: topHeight),
            .area3: CGRect(x: 0, y: bottomY, width: halfLeft, height: stripHeight),
            .area4: CGRect(x: halfLeft + spacing, y: bottomY, width: halfLeft, height: stripHeight),
            .area5: CGRect(x: rightX, y: bottomY, width: halfRight, height: stripHeight),
            .area6: CGRect(x: rightX + halfRight + spacing, y: bottomY, width: halfRight, height: stripHeight),
        ]
    }

    static func placements(width: CGFloat, filled: Set<DashboardArea>) -> [DashboardArea: Placement] {
        let base = frames(in: CGSize(width: width, height: fullHeight))
        let leftWidth = base[.area1]?.width ?? width
        var result: [DashboardArea: Placement] = [:]

        let hasTop = filled.contains(.area1) || filled.contains(.area2)
        if filled.contains(.area1), filled.contains(.area2) {
            result[.area1] = Placement(frame: base[.area1] ?? .zero, slot: .wide, widensQuick: false)
            result[.area2] = Placement(frame: base[.area2] ?? .zero, slot: .medium, widensQuick: false)
        } else if let only = [DashboardArea.area1, .area2].first(where: filled.contains) {
            result[only] = Placement(
                frame: CGRect(x: 0, y: 0, width: width, height: topHeight),
                slot: .wide,
                widensQuick: false
            )
        }

        let y = hasTop ? topHeight + spacing : 0
        let strips = [DashboardArea.area3, .area4].filter(filled.contains)
        let quicks = [DashboardArea.area5, .area6].filter(filled.contains)
        let stripSpan: ClosedRange<CGFloat>
        let quickSpan: ClosedRange<CGFloat>
        if !strips.isEmpty, !quicks.isEmpty {
            stripSpan = 0...leftWidth
            quickSpan = (leftWidth + spacing)...width
        } else {
            stripSpan = 0...width
            quickSpan = 0...width
        }
        for (index, frame) in split(stripSpan, count: strips.count, y: y).enumerated() {
            result[strips[index]] = Placement(frame: frame, slot: .strip, widensQuick: false)
        }
        for (index, frame) in split(quickSpan, count: quicks.count, y: y).enumerated() {
            result[quicks[index]] = Placement(frame: frame, slot: .quick, widensQuick: frame.width > 150)
        }
        return result
    }

    private static func split(_ span: ClosedRange<CGFloat>, count: Int, y: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let total = span.upperBound - span.lowerBound
        let each = (total - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { index in
            CGRect(x: span.lowerBound + CGFloat(index) * (each + spacing), y: y, width: each, height: stripHeight)
        }
    }
}

/// The island's dashboard: only filled areas, laid out by `DashboardLayout`.
struct DashboardCollapsedGrid<Cell: View>: View {
    let filled: Set<DashboardArea>
    @ViewBuilder let cell: (DashboardArea, DashboardLayout.Placement) -> Cell

    var body: some View {
        GeometryReader { proxy in
            let placements = DashboardLayout.placements(width: proxy.size.width, filled: filled)
            ZStack(alignment: .topLeading) {
                ForEach(DashboardArea.allCases) { area in
                    if let placement = placements[area] {
                        cell(area, placement)
                            .frame(width: placement.frame.width, height: placement.frame.height)
                            .offset(x: placement.frame.minX, y: placement.frame.minY)
                    }
                }
            }
        }
    }
}

// MARK: - Grid

/// The six dashboard areas, laid out from one set of frames so the island and
/// the Settings editor agree on where every slot is, down to the point.
struct DashboardGrid<Cell: View>: View {
    @ViewBuilder let cell: (DashboardArea) -> Cell

    static var spacing: CGFloat { 8 }
    static var stripHeight: CGFloat { 54 }

    /// The dashboard's content size inside a 760pt island: flare and padding
    /// taken off the width, top and bottom padding off the 300pt height.
    static var naturalSize: CGSize { CGSize(width: 704, height: DashboardLayout.fullHeight) }

    static func frames(in size: CGSize) -> [DashboardArea: CGRect] {
        DashboardLayout.frames(in: size)
    }

    var body: some View {
        GeometryReader { proxy in
            let frames = Self.frames(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(DashboardArea.allCases) { area in
                    let frame = frames[area] ?? .zero
                    cell(area)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }
}

// MARK: - Surface

/// A widget's well. Widgets are neutral in every appearance: white is the
/// accent, amber means an agent is waiting on you.
private struct DashboardWell: ViewModifier {
    let appearance: IslandAppearance

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay {
                if let stroke { shape.strokeBorder(stroke, lineWidth: 0.5) }
            }
            .clipShape(shape)
    }

    private var fill: Color {
        switch appearance {
        // On black the fill alone draws the card. A hairline on top of it
        // read as a grey box with a rim; a barely-there fill is enough.
        case .solidBlack: .white.opacity(0.01)
        case .glass: .black.opacity(0.16)
        case .hybrid: .white.opacity(0.01)
        }
    }

    /// Glass only: over an arbitrary backdrop the fill cannot hold the edge.
    private var stroke: Color? {
        appearance == .glass ? .white.opacity(0.12) : nil
    }
}

extension View {
    func dashboardWell(_ appearance: IslandAppearance) -> some View {
        modifier(DashboardWell(appearance: appearance))
    }
}

enum DashboardStyle {
    static let amber = Color(red: 1, green: 0.70, blue: 0.25)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)

    static func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
        }
        .foregroundStyle(tertiary)
    }

    static func digits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    static func elapsed(since date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let minutes = max(Int(now.timeIntervalSince(date) / 60), 0)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}

/// A thin white bar. Drawn by hand so it matches the rest of the widget and
/// renders identically in Settings previews.
struct DashboardBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Small pill button used across widgets.
private struct DashboardPillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                }
                if !title.isEmpty {
                    Text(title)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, title.isEmpty ? 7 : 10)
            .frame(height: 22)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(prominent ? Color.white : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.nanoPress)
    }
}

private struct DashboardCircleButton: View {
    let symbol: String
    var size: CGFloat = 32
    var prominent = true
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(prominent ? Color.white : Color.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.nanoPress)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Widget

/// One feature rendered for one slot. Buttons inside a widget act directly;
/// a tap anywhere else opens the feature.
struct DashboardWidget: View {
    let module: NanoModuleID
    let slot: DashboardSlot
    var widensQuick = false
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    let action: () -> Void

    var body: some View {
        Group {
            if slot == .quick, widensQuick {
                HStack(spacing: 10) {
                    content
                        .fixedSize()
                    Text(module.dashboardTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            } else {
                content
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(padding)
            .foregroundStyle(.white)
            .dashboardWell(settings.appearance)
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .onTapGesture(perform: action)
            .nanoPressable()
            .nanoHoverLift()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(module.title)
            .accessibilityAction(named: "Open \(module.title)", action)
    }

    private var padding: EdgeInsets {
        switch slot {
        case .wide: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14)
        case .medium: EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13)
        case .strip: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        case .quick: EdgeInsets()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .music:
            DashboardMusicWidget(controller: viewModel.mediaController, slot: slot)
        case .calendar:
            Group {
                if slot == .wide {
                    DashboardCalendarWidget(
                        service: viewModel.calendarService,
                        isPrimary: true,
                        openCalendar: action,
                        includes: settings.showsOnDashboard
                    )
                } else {
                    DashboardNextEventWidget(service: viewModel.calendarService, settings: settings, slot: slot)
                }
            }
            .onAppear { viewModel.calendarService.hiddenCalendarTitles = settings.hiddenCalendars }
        case .weather:
            DashboardWeatherWidget(
                service: viewModel.weatherService,
                locationName: settings.weatherLocationName,
                needsCurrentLocation: settings.weatherUsesCurrentLocation && !settings.weatherHasLocation,
                slot: slot
            )
        case .agents:
            DashboardAgentsWidget(
                sessionStore: viewModel.sessionStore,
                hookBridge: viewModel.hookBridge,
                agentService: viewModel.agentService,
                settings: settings,
                slot: slot
            )
        case .timer:
            DashboardTimerWidget(store: viewModel.timerStore, slot: slot)
        case .cue:
            DashboardCueWidget(store: viewModel.cueStore)
        case .tray:
            DashboardTrayWidget(store: viewModel.trayStore, settings: settings)
        case .battery:
            DashboardBatteryWidget(service: viewModel.systemStatusService, slot: slot)
        case .camera:
            DashboardLauncherWidget(
                slot: slot,
                symbol: "camera.fill",
                title: "Camera",
                subtitle: "Mirror check"
            )
        default:
            DashboardLauncherWidget(
                slot: slot,
                symbol: module.symbol,
                title: module.dashboardTitle,
                subtitle: module.title
            )
        }
    }
}

// MARK: - Music

struct DashboardMusicWidget: View {
    @ObservedObject var controller: MediaController
    let slot: DashboardSlot

    var body: some View {
        if slot == .wide {
            DashboardMusicView(controller: controller, openModule: {})
        } else {
            medium
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                MediaArtwork(controller: controller, size: 74, cornerRadius: 12, symbolSize: 26)
                Spacer(minLength: 0)
                if let track = controller.nowPlaying {
                    NanoWave(barWidth: 2.5, height: 14, color: track.player.accentColor, isActive: track.isPlaying)
                } else if controller.automationNote == nil {
                    MediaIdlePill(controller: controller)
                }
            }
            Spacer(minLength: 6)
            Text(controller.nowPlaying?.title ?? controller.lastPlayed?.title ?? "Nothing playing")
                .font(.system(size: 14, weight: .semibold))
                .opacity(controller.nowPlaying == nil && controller.lastPlayed != nil ? 0.75 : 1)
                .lineLimit(1)
            Text(controller.nowPlaying?.artist ?? controller.lastPlayed?.artist ?? "Spotify or Apple Music")
                .font(.system(size: 11))
                .foregroundStyle(DashboardStyle.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if controller.nowPlaying != nil {
                MediaProgressRow(controller: controller, showsTimes: false)
                HStack {
                    Button(action: controller.previousTrack) { Image(systemName: "backward.fill") }
                        .help("Previous track")
                    Spacer()
                    DashboardCircleButton(
                        symbol: controller.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                        size: 34,
                        help: "Play or pause",
                        action: controller.playPause
                    )
                    Spacer()
                    Button(action: controller.nextTrack) { Image(systemName: "forward.fill") }
                        .help("Next track")
                }
                .buttonStyle(.nanoPress)
                .font(.system(size: 13))
                .padding(.top, 3)
            } else if let note = controller.automationNote {
                // Without Automation, Resume would do nothing. Say what to fix instead.
                Text(note)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DashboardStyle.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let last = controller.lastPlayed {
                MediaLastPlayedLine(lastPlayed: last)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DashboardStyle.tertiary)
            }
        }
    }
}

// MARK: - Calendar

/// How far off an event is, in words. An all-day event is only "Today" on
/// its day: Columbus Day two weeks out is "Oct 12".
enum NanoEventTiming {
    /// The large label on the next event: "in 20m", "Tomorrow", "Thu", "Oct 12".
    static func countdown(start: Date, isAllDay: Bool, now: Date, calendar: Calendar = .current) -> String {
        if start <= now { return isAllDay ? "Today" : "Now" }
        if !isAllDay {
            let minutes = Int(start.timeIntervalSince(now) / 60)
            if minutes < 60 { return "in \(max(minutes, 1))m" }
            if calendar.isDate(start, inSameDayAs: now) { return "in \(minutes / 60)h" }
        }
        return day(start, now: now, calendar: calendar)
    }

    /// A smaller row: the time on today's events, the day in front otherwise.
    static func listLine(start: Date, isAllDay: Bool, now: Date, calendar: Calendar = .current) -> String {
        let time = isAllDay ? "All day" : start.formatted(date: .omitted, time: .shortened)
        guard start > now, !calendar.isDate(start, inSameDayAs: now) else { return time }
        return "\(day(start, now: now, calendar: calendar)) · \(time)"
    }

    /// "Today", "Tomorrow", a weekday within the week, then a date.
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Tomorrow"
        case 2..<7: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

private struct DashboardNextEventWidget: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var settings: NanoSettings
    let slot: DashboardSlot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if slot == .strip {
                strip(now: context.date)
            } else {
                medium(now: context.date)
            }
        }
    }

    /// Holidays and birthdays never take the headline; they stay on the Calendar's dates.
    private func upcoming(now: Date) -> [NanoCalendarEvent] {
        service.events
            .filter { $0.endDate > now && !$0.isHoliday && settings.showsOnDashboard($0) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func countdown(_ event: NanoCalendarEvent, now: Date) -> String {
        NanoEventTiming.countdown(start: event.startDate, isAllDay: event.isAllDay, now: now)
    }

    private func time(_ event: NanoCalendarEvent) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    @ViewBuilder
    private func medium(now: Date) -> some View {
        let events = upcoming(now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DashboardStyle.label("Calendar", symbol: "calendar")
                Spacer()
                Text(now.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DashboardStyle.tertiary)
            }
            if !service.hasFullAccess {
                placeholder("Enable Calendar", symbol: "calendar.badge.exclamationmark")
            } else if let next = events.first {
                Spacer(minLength: 8)
                Text(countdown(next, now: now))
                    .font(DashboardStyle.digits(24))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: countdown(next, now: now))
                Text(next.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 5)
                Text(time(next))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardStyle.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ForEach(events.dropFirst().prefix(2)) { event in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(event.calendarColorHex))
                            .frame(width: 3, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Text(NanoEventTiming.listLine(start: event.startDate, isAllDay: event.isAllDay, now: now))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(DashboardStyle.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                placeholder("Nothing scheduled", symbol: "calendar.badge.checkmark")
            }
        }
    }

    @ViewBuilder
    private func strip(now: Date) -> some View {
        if !service.hasFullAccess {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 17))
                Text("Enable Calendar").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
        } else if let next = upcoming(now: now).first {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(next.calendarColorHex))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(time(next))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(countdown(next, now: now))
                    .font(DashboardStyle.digits(14))
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "calendar").font(.system(size: 17))
                Text("Nothing scheduled").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashboardStyle.secondary)
        }
    }

    private func placeholder(_ title: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(DashboardStyle.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(_ hex: String) -> Color {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Weather

private struct DashboardWeatherWidget: View {
    @ObservedObject var service: NanoWeatherService
    let locationName: String
    /// Weather follows this Mac's location and no place has been found yet.
    var needsCurrentLocation = false
    let slot: DashboardSlot

    private var snapshot: NanoWeatherSnapshot? { service.snapshot }

    private var temperature: String {
        snapshot.map { NanoTemperature.text($0.temperature) } ?? ""
    }

    /// Why there is no forecast, when that is known.
    private var waitingTitle: String {
        if needsCurrentLocation, service.locationAccessIsOff { return "Location is off" }
        return service.shortFailureReason ?? "No forecast yet"
    }

    private var place: String {
        if let name = snapshot?.placeName, !name.isEmpty { return name }
        let trimmed = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Set a location" : trimmed
    }

    private var highLow: String? {
        guard let high = snapshot?.high, let low = snapshot?.low else { return nil }
        return NanoTemperature.highLow(high: high, low: low)
    }

    var body: some View {
        switch slot {
        case .wide where snapshot == nil, .medium where snapshot == nil: waiting
        case .wide: wide
        case .medium: medium
        case .strip: strip
        case .quick: quick
        }
    }

    /// No forecast yet: location unset, permission pending, first fetch, or a
    /// failure, named when the reason is known.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardStyle.label("Weather", symbol: "cloud.sun.fill")
            VStack(spacing: 6) {
                symbol(nil, size: 26)
                Text(waitingTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(place)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardStyle.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func symbol(_ name: String?, size: CGFloat) -> some View {
        Image(systemName: name ?? "cloud.sun.fill")
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
    }

    private var wide: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        DashboardStyle.label("Weather", symbol: "cloud.sun.fill")
                        Text("· \(place)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(DashboardStyle.tertiary)
                            .lineLimit(1)
                    }
                    HStack(alignment: .center, spacing: 12) {
                        if snapshot != nil {
                            Text(temperature)
                                .font(.system(size: 48, weight: .semibold, design: .rounded))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot?.condition ?? "No forecast yet")
                                .font(.system(size: 13, weight: .semibold))
                            if let highLow {
                                Text(highLow)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DashboardStyle.secondary)
                            }
                        }
                    }
                }
                Spacer()
                symbol(snapshot?.symbolName, size: 40)
            }
            Spacer(minLength: 6)
            hourly(count: 6)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                DashboardStyle.label("Weather", symbol: "cloud.sun.fill")
                Spacer()
                symbol(snapshot?.symbolName, size: 26)
            }
            Spacer(minLength: 4)
            Text(snapshot == nil ? "Weather" : temperature)
                .font(.system(size: snapshot == nil ? 22 : 44, weight: .semibold, design: .rounded))
            Text(snapshot?.condition ?? "No forecast yet")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(highLow ?? place)
                .font(.system(size: 11))
                .foregroundStyle(DashboardStyle.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            hourly(count: 3, stride: 2)
        }
    }

    private var strip: some View {
        HStack(spacing: 9) {
            symbol(snapshot?.symbolName, size: 22)
            if snapshot != nil {
                Text(temperature)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot?.condition ?? "Weather")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(highLow ?? place)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardStyle.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var quick: some View {
        VStack(spacing: 3) {
            symbol(snapshot?.symbolName, size: 19)
            if snapshot != nil {
                Text(temperature)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DashboardStyle.secondary)
            }
        }
    }

    @ViewBuilder
    private func hourly(count: Int, stride step: Int = 1) -> some View {
        let hours = Array(Swift.stride(from: 0, to: snapshot?.hours.count ?? 0, by: step)
            .prefix(count)
            .compactMap { snapshot?.hours[$0] })
        if hours.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                ForEach(hours) { hour in
                    VStack(spacing: 4) {
                        Text(hour.date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(DashboardStyle.secondary)
                        symbol(hour.symbolName, size: 15)
                        Text(NanoTemperature.text(hour.temperature))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(DashboardStyle.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Agents

private struct DashboardAgentsWidget: View {
    @ObservedObject var sessionStore: AgentSessionStore
    @ObservedObject var hookBridge: AgentHookBridge
    @ObservedObject var agentService: AgentStatusService
    @ObservedObject var settings: NanoSettings
    let slot: DashboardSlot

    private var sessions: [AgentSession] {
        sessionStore.liveSessions
    }

    /// A blocked permission request Nano can answer from here.
    private var approval: AgentHookBridge.PendingRequest? {
        hookBridge.pending.first { $0.kind == .permission && $0.respondsThroughBridge && !$0.isResolved }
    }

    private var waitingCount: Int {
        max(sessions.filter(\.needsAttention).count, hookBridge.pending.filter { $0.kind == .permission && !$0.isResolved }.count)
    }

    private var usage: (provider: AgentProviderID, window: NanoUsageWindow)? {
        agentService.snapshots
            .filter(\.hasQuota)
            .flatMap { snapshot in snapshot.usage.map { (snapshot.id, $0) } }
            .max { $0.1.usedPercent < $1.1.usedPercent }
            .map { (provider: $0.0, window: $0.1) }
    }

    private var usagePercent: Double? {
        guard let usage else { return nil }
        return settings.usageDisplayMode == .used ? usage.window.usedPercent : usage.window.remainingPercent
    }

    var body: some View {
        switch slot {
        case .wide: wide
        case .medium: medium
        case .strip: strip
        case .quick: quick
        }
    }

    // Wide and medium: the Agents module's own rows, compact. What needs you
    // comes first; the half-width slot drops the model column to fit.
    private var wide: some View { sessionRows(showsDetails: true) }
    private var medium: some View { sessionRows(showsDetails: false) }

    private func sessionRows(showsDetails: Bool) -> some View {
        let limit = approval == nil ? 4 : 1
        let shown = Array(sessions.prefix(limit))
        return VStack(alignment: .leading, spacing: 4) {
            if let approval {
                approvalCard(approval)
            }
            if sessions.isEmpty {
                empty
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                    HStack(alignment: .top, spacing: 4) {
                        AgentSessionRow(session: session, compact: true, showsDetails: showsDetails)
                        AgentJumpButton(session: session)
                            .padding(.top, 7)
                    }
                    if index < shown.count - 1 {
                        Rectangle()
                            .fill(.white.opacity(0.07))
                            .frame(height: 1)
                            .padding(.horizontal, 6)
                    }
                }
                Spacer(minLength: 0)
                if sessions.count > shown.count {
                    Text("+\(sessions.count - shown.count) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DashboardStyle.tertiary)
                        .padding(.leading, 6)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 20))
            Text("Nothing running")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(DashboardStyle.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func approvalCard(_ request: AgentHookBridge.PendingRequest) -> some View {
        let risk = AgentModuleView.risk(of: request)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(DashboardStyle.amber).frame(width: 6, height: 6)
                Text([request.projectName, providerName(request.source)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardStyle.amber)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let risk {
                    Text(risk)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.34))
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .overlay(Capsule().stroke(Color(red: 1.0, green: 0.36, blue: 0.34).opacity(0.5), lineWidth: 0.75))
                        .lineLimit(1)
                }
            }
            Text(AgentApprovalCopy.shortHeadline(tool: request.title, preview: request.preview))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            if let subject = subject(of: request) {
                Text(subject)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            HStack(spacing: 5) {
                if let deny = request.options.first(where: { $0.id == 0 }) {
                    DashboardPillButton(title: AgentApprovalCopy.optionLabel(deny, preview: request.preview)) {
                        hookBridge.respond(to: request.id, choice: deny.id)
                    }
                }
                if let allow = request.options.first(where: { $0.id == 1 }) ?? request.options.last {
                    DashboardPillButton(title: AgentApprovalCopy.optionLabel(allow, preview: request.preview), prominent: true) {
                        hookBridge.respond(to: request.id, choice: allow.id)
                    }
                }
                Spacer(minLength: 0)
                // The tile opens the Agents module, where the full card is.
                HStack(spacing: 2) {
                    Text("Details")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DashboardStyle.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardStyle.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(DashboardStyle.amber.opacity(0.35), lineWidth: 0.5)
        }
    }

    // Strip: which models are working, and whether anyone is waiting on you.
    // The logos are the compact island's, so both read the same at a glance.
    private var strip: some View {
        HStack(spacing: 9) {
            if runningProviders.isEmpty {
                Image(systemName: "terminal")
                    .font(.system(size: 17))
                    .foregroundStyle(DashboardStyle.tertiary)
            } else {
                CompactAgentLogoGroup(providers: runningProviders)
            }
            VStack(alignment: .leading, spacing: 2) {
                if waitingCount > 0 {
                    Text("Needs you")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DashboardStyle.amber)
                } else if let runningModels {
                    Text(runningModels)
                        .font(.system(size: 11.5, weight: .semibold))
                } else {
                    Text("Nothing running")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DashboardStyle.secondary)
                }
                Text(stripDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardStyle.tertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// Sessions mid-turn or waiting on you. Idle ones stay off the strip.
    private var runningSessions: [AgentSession] {
        sessions.filter { $0.isActive || $0.needsAttention }
    }

    private var runningProviders: [CompactAgentActivitySummary.ProviderActivity] {
        let counts = Dictionary(grouping: runningSessions, by: \.provider).mapValues(\.count)
        return AgentProviderID.supported.compactMap { provider in
            counts[provider].map { .init(provider: provider, sessionCount: $0) }
        }
    }

    /// "Opus 5.5 · GPT-6": each model a running session is on, once. A session
    /// that has not reported its model yet counts as its provider.
    private var runningModels: String? {
        var names: [String] = []
        for session in runningSessions {
            let name = session.model.map(AgentModuleView.modelName) ?? session.provider.title
            if !names.contains(name) { names.append(name) }
        }
        switch names.count {
        case 0: return nil
        case 1, 2: return names.joined(separator: " · ")
        default: return "\(names[0]) · \(names[1]) +\(names.count - 2)"
        }
    }

    private var stripDetail: String {
        if let waiting = sessions.first(where: \.needsAttention) ?? approval.flatMap({ request in
            sessions.first { $0.id == request.sessionID }
        }) {
            let others = sessions.filter { $0.isActive && $0.id != waiting.id }.count
            return others > 0 ? "\(waiting.projectName) · \(others) working" : waiting.projectName
        }
        if let first = runningSessions.first {
            return "\(first.projectName) · \(activity(first))"
        }
        if let usagePercent, let usage {
            let base = "\(usage.provider.title) \(Int(usagePercent.rounded()))% \(settings.usageDisplayMode == .used ? "used" : "left")"
            return usage.window.resetCountdown.map { "\(base), resets \($0)" } ?? base
        }
        return "Start an agent to see it here"
    }

    // Quick: one ring segment per session.
    private var quick: some View {
        let states = sessions.prefix(6).map(avatarState)
        return ZStack(alignment: .topTrailing) {
            ZStack {
                SegmentRing(colors: states.map(\.color))
                    .frame(width: 36, height: 36)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if waitingCount > 0 {
                Text("\(waitingCount)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(DashboardStyle.amber, in: Capsule())
                    .padding(6)
            }
        }
    }

    private func avatarState(_ session: AgentSession) -> AgentWidgetStatus {
        if session.needsAttention { return .waiting }
        return session.isActive ? .working : .idle
    }

    private func activity(_ session: AgentSession) -> String {
        if let current = session.currentActivity, !current.isEmpty { return current }
        return session.displayName
    }

    private func providerName(_ source: String) -> String? {
        AgentProviderID.normalize(source).flatMap(AgentProviderID.init(rawValue:))?.title
    }

    /// What the headline does not already say: the command, the first
    /// changed line, the plan's first step, the tool's arguments.
    private func subject(of request: AgentHookBridge.PendingRequest) -> String? {
        switch request.preview {
        case let .command(command): command
        case let .diff(_, removed, added, _): (added.first ?? removed.first).map { "+ \($0)" }
        case let .plan(markdown): AgentPlanSummary.parse(markdown).steps.first.map { "1. \($0)" }
        case let .arguments(fields): fields.joined(separator: "  ")
        case .none: request.detail
        }
    }
}

/// How a session reads in the Agents widget's segment ring.
private enum AgentWidgetStatus {
    case working
    case waiting
    case idle

    var color: Color {
        switch self {
        case .working: .white
        case .waiting: DashboardStyle.amber
        case .idle: .white.opacity(0.3)
        }
    }
}

/// A ring split into equal segments with small gaps, one colour each.
private struct SegmentRing: View {
    let colors: [Color]
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            if colors.isEmpty {
                Circle().stroke(.white.opacity(0.15), lineWidth: lineWidth)
            } else {
                let gap = colors.count > 1 ? 0.03 : 0
                let share = 1 / Double(colors.count)
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .trim(from: Double(index) * share + gap / 2, to: Double(index + 1) * share - gap / 2)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
        .rotationEffect(.degrees(-90))
    }
}

// MARK: - Timer

private struct DashboardTimerWidget: View {
    @ObservedObject var store: FocusTimerStore
    let slot: DashboardSlot

    private var isRunning: Bool { store.state == .running }

    private var tint: Color {
        store.mode == .rest ? Color(red: 0.42, green: 0.84, blue: 0.74) : .white
    }

    private var status: String {
        switch store.state {
        case .running:
            "Ends \(Date().addingTimeInterval(store.remaining).formatted(date: .omitted, time: .shortened))"
        case .paused: "Paused"
        case .completed: store.mode == .rest ? "Break's over" : "Session done"
        case .idle: "Ready · \(Int(store.configuredDuration / 60)) min"
        }
    }

    /// The current goal, or what comes after.
    private var nextLabel: String {
        if store.mode == .rest { return "Then back to it" }
        if let goal = store.nextTask { return goal.title }
        return "Then a \(Int(store.suggestedBreak / 60)) min break"
    }

    var body: some View {
        switch slot {
        case .wide: wide
        case .medium: medium
        case .strip: strip
        case .quick: quick
        }
    }

    private func toggle() {
        isRunning ? store.pause() : store.startOrResume()
    }

    private var playButton: some View {
        DashboardCircleButton(
            symbol: isRunning ? "pause.fill" : "play.fill",
            size: slot == .wide ? 34 : 32,
            help: isRunning ? "Pause" : "Start",
            action: toggle
        )
    }

    // Wide: the session as a track, every block in proportion, with a playhead.
    private var wide: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DashboardStyle.label("Timer · \(store.mode.title)", symbol: "timer")
                Spacer()
                if !store.tasks.isEmpty {
                    Text("\(store.completedTaskCount) of \(store.tasks.count) goals")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                }
            }
            Spacer(minLength: 4)
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                Text(store.formattedRemaining)
                    .font(DashboardStyle.digits(66))
                    .tracking(-1.5)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.3), value: store.formattedRemaining)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardStyle.secondary)
                    Text(nextLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                }
                .padding(.bottom, 6)
            }
            Spacer(minLength: 8)
            bar
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                playButton
                if store.canUndoReset {
                    DashboardPillButton(title: "Undo reset") { store.undoReset() }
                } else {
                    DashboardPillButton(title: "+5 min") { store.addTime(300) }
                        .help("Add five minutes")
                }
                Spacer()
                DashboardCircleButton(symbol: "stop.fill", size: 28, prominent: false, help: "Stop") {
                    store.reset()
                }
            }
        }
    }

    /// How far through the session or break.
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * (store.state == .idle ? 0 : store.progress))
            }
        }
        .frame(height: 6)
    }

    // Medium: digits first, then how far along and what's next.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DashboardStyle.label("Timer", symbol: "timer")
                Spacer()
                Text(store.mode.title)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardStyle.tertiary)
            }
            Spacer(minLength: 4)
            Text(store.formattedRemaining)
                .font(DashboardStyle.digits(48))
                .tracking(-1.2)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.3), value: store.formattedRemaining)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(DashboardStyle.secondary)
                .padding(.top, 4)
            Spacer(minLength: 8)
            bar
            Text(nextLabel)
                .font(.system(size: 10))
                .foregroundStyle(DashboardStyle.tertiary)
                .lineLimit(1)
                .padding(.top, 5)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                playButton
                DashboardPillButton(title: "+5") { store.addTime(300) }
                    .help("Add five minutes")
            }
        }
    }

    private var strip: some View {
        HStack(spacing: 10) {
            ring(size: 30, lineWidth: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.formattedRemaining)
                    .font(DashboardStyle.digits(17))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.3), value: store.formattedRemaining)
                Text("\(store.mode.title) · \(status)")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardStyle.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            DashboardCircleButton(
                symbol: isRunning ? "pause.fill" : "play.fill",
                size: 28,
                prominent: false,
                help: isRunning ? "Pause" : "Start",
                action: toggle
            )
        }
    }

    private var quick: some View {
        ZStack {
            ring(size: 36, lineWidth: 3)
            Image(systemName: isRunning ? "pause.fill" : "timer")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func ring(size: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: store.state == .idle ? 0 : store.progress)
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Cue

private struct DashboardCueWidget: View {
    @ObservedObject var store: CueStore

    private var open: [CueItem] { store.items.filter { !$0.isDone } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DashboardStyle.label("Cue", symbol: "checklist")
                Spacer()
                if let folder = open.first?.folderID.flatMap({ id in store.folders.first { $0.id == id } }) {
                    Label(folder.name, systemImage: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DashboardStyle.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(.white.opacity(0.08), in: Capsule())
                }
            }
            if open.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 20))
                    Text("Nothing queued").font(.system(size: 11, weight: .medium))
                    Text("⌃⌥C captures a to-do, prompt, or screenshot")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                }
                .foregroundStyle(DashboardStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Up next")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardStyle.tertiary)
                    .padding(.top, 6)
                    .padding(.bottom, 3)
                ForEach(Array(open.prefix(3).enumerated()), id: \.element.id) { index, item in
                    row(item, isNext: index == 0)
                }
                Spacer(minLength: 0)
                HStack {
                    if open.count > 3 {
                        Text("+\(open.count - 3) more")
                    }
                    Spacer()
                    Text("⌃⌥C to capture")
                }
                .font(.system(size: 10))
                .foregroundStyle(DashboardStyle.tertiary)
            }
        }
    }

    private func row(_ item: CueItem, isNext: Bool) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.white.opacity(isNext ? 0.75 : 0.3), lineWidth: 1.3)
                .frame(width: 14, height: 14)
            Text(item.headline)
                .font(.system(size: 11.5, weight: isNext ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !item.images.isEmpty {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardStyle.tertiary)
            }
        }
        .padding(.horizontal, isNext ? 8 : 0)
        .padding(.vertical, isNext ? 6 : 5)
        .background(.white.opacity(isNext ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, isNext ? -8 : 0)
    }
}

// MARK: - Tray

private struct DashboardTrayWidget: View {
    @ObservedObject var store: TrayStore
    @ObservedObject var settings: NanoSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DashboardStyle.label("Tray", symbol: "tray.full.fill")
                Spacer()
                if store.canUndo, let message = store.message {
                    HStack(spacing: 6) {
                        Text(message)
                            .foregroundStyle(DashboardStyle.tertiary)
                        Button("Undo") { store.undoDiscard() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                } else {
                    Text(store.items.isEmpty ? "Empty" : "\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                }
            }
            if store.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 18))
                    Text("Drag a file to the notch")
                        .font(.system(size: 11, weight: .medium))
                    Text("It waits here until you need it")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                }
                .foregroundStyle(DashboardStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(store.items.prefix(5)) { item in
                        VStack(spacing: 5) {
                            TrayThumbnail(url: item.url, side: 46)
                            Text(item.name)
                                .font(.system(size: 10))
                                .foregroundStyle(DashboardStyle.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(width: 66)
                        .overlay(
                            TrayFileDragSource(
                                urls: [item.url],
                                onDoubleClick: { store.open(item) },
                                menuItems: { TrayItemMenu.items(for: item, store: store) },
                                onDragEnded: { delivered in
                                    if delivered, settings.trayRemovesAfterDragOut {
                                        store.remove(urls: [item.url])
                                    }
                                }
                            )
                        )
                        .help(item.url.path)
                    }
                    if store.items.count > 5 {
                        Text("+\(store.items.count - 5)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DashboardStyle.secondary)
                            .frame(width: 40)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        DashboardCircleButton(symbol: "dot.radiowaves.left.and.right", size: 30, prominent: false, help: "AirDrop everything") {
                            store.sendViaAirDrop()
                        }
                        dragAll
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear(perform: store.pruneMissing)
    }

    /// Every held file in one drag.
    private var dragAll: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.1), in: Circle())
            .overlay(
                TrayFileDragSource(
                    urls: store.items.map(\.url),
                    onDragEnded: { delivered in
                        if delivered, settings.trayRemovesAfterDragOut {
                            store.remove(urls: store.items.map(\.url))
                        }
                    }
                )
            )
            .help("Drag everything held at once")
    }
}

// MARK: - Battery, Focus, launchers

private struct DashboardBatteryWidget: View {
    @ObservedObject var service: SystemStatusService
    let slot: DashboardSlot

    var body: some View {
        let battery = service.battery
        Group {
            if let battery {
                HStack(spacing: 10) {
                    Image(systemName: battery.hudSymbol)
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(battery.percentage)%")
                                .font(DashboardStyle.digits(15))
                            Spacer()
                            Text(detail(battery))
                                .font(.system(size: 10))
                                .foregroundStyle(DashboardStyle.tertiary)
                                .lineLimit(1)
                        }
                        DashboardBar(value: Double(battery.percentage) / 100)
                    }
                }
            } else {
                // A desktop Mac: no level to draw, so no glyph that implies one.
                HStack(spacing: 10) {
                    Image(systemName: "powerplug.fill")
                        .font(.system(size: 17))
                    Text("No battery")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DashboardStyle.secondary)
            }
        }
        .onAppear { service.refresh() }
    }

    private func detail(_ battery: BatterySnapshot) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Plugged in" }
        guard let minutes = battery.timeRemainingMinutes, minutes > 0 else { return "On battery" }
        return "\(minutes / 60)h \(minutes % 60)m left"
    }
}

private struct DashboardLauncherWidget: View {
    let slot: DashboardSlot
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        if slot == .quick {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .help(title)
        } else {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardStyle.tertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DashboardStyle.tertiary)
            }
        }
    }
}

// MARK: - Per-widget options

/// One option for a dashboard widget. The island's right-click menu and the
/// Settings editor's slot picker both render these, so they always match.
struct DashboardWidgetOption: Identifiable {
    enum Kind {
        case header
        case toggle(Bool)
        case action
        case destructive
    }

    let id = UUID()
    let title: String
    let kind: Kind
    var perform: @MainActor () -> Void = {}
}

@MainActor
enum DashboardWidgetOptions {
    /// Sections of options for `module` in `area`. Feature options first,
    /// then the common ones.
    static func sections(
        for module: NanoModuleID,
        in area: DashboardArea,
        settings: NanoSettings,
        viewModel: IslandViewModel,
        includesCommon: Bool = true
    ) -> [[DashboardWidgetOption]] {
        var sections: [[DashboardWidgetOption]] = []
        let feature = featureOptions(for: module, settings: settings, viewModel: viewModel)
        if !feature.isEmpty { sections.append(feature) }
        if includesCommon {
            sections.append([
                DashboardWidgetOption(title: "Open \(module.dashboardTitle)", kind: .action) {
                    viewModel.openModule(module)
                },
                DashboardWidgetOption(title: "Edit Dashboard…", kind: .action) {
                    NotificationCenter.default.post(name: .nanoOpenSettings, object: SettingsDestination.dashboard.rawValue)
                },
                DashboardWidgetOption(title: "Remove from Dashboard", kind: .destructive) {
                    settings.setDashboardFeature(nil, in: area)
                },
            ])
        }
        return sections
    }

    static func featureOptions(
        for module: NanoModuleID,
        settings: NanoSettings,
        viewModel: IslandViewModel
    ) -> [DashboardWidgetOption] {
        switch module {
        case .music:
            let players: [(String, MediaPlayerKind?)] = [("Automatic", nil)] + MediaPlayerKind.allCases.map { ($0.title, $0) }
            return [DashboardWidgetOption(title: "Player", kind: .header)] + players.map { title, player in
                DashboardWidgetOption(title: title, kind: .toggle(settings.preferredMediaPlayer == player)) {
                    settings.preferredMediaPlayer = player
                }
            } + [
                DashboardWidgetOption(title: "Show Song Changes", kind: .toggle(settings.musicAnnouncesTrackChanges)) {
                    settings.musicAnnouncesTrackChanges.toggle()
                },
            ]
        case .calendar:
            let calendars = viewModel.calendarService.eventCalendars
            var options: [DashboardWidgetOption] = [DashboardWidgetOption(title: "View", kind: .header)]
            options += CalendarLayout.allCases.map { layout in
                DashboardWidgetOption(title: layout.title, kind: .toggle(settings.calendarLayout == layout)) {
                    settings.calendarLayout = layout
                }
            }
            if !calendars.isEmpty {
                options.append(DashboardWidgetOption(title: "Show Events From", kind: .header))
                options += calendars.map { calendar in
                    DashboardWidgetOption(
                        title: calendar.title,
                        kind: .toggle(!settings.isCalendarHidden(id: calendar.id, title: calendar.title))
                    ) {
                        settings.setCalendarHidden(
                            !settings.isCalendarHidden(id: calendar.id, title: calendar.title),
                            id: calendar.id,
                            title: calendar.title,
                            sameTitleIDs: calendars.filter { $0.title == calendar.title }.map(\.id)
                        )
                        viewModel.calendarService.hiddenCalendarTitles = settings.hiddenCalendars
                    }
                }
            }
            options.append(DashboardWidgetOption(title: "All-Day Events", kind: .toggle(settings.calendarShowsAllDay)) {
                settings.calendarShowsAllDay.toggle()
            })
            return options
        case .timer:
            let store = viewModel.timerStore
            return [
                DashboardWidgetOption(title: "Timer", kind: .header),
                DashboardWidgetOption(title: "Start 25 Minute Session", kind: .action) {
                    store.startFocus(minutes: 25)
                },
                DashboardWidgetOption(title: "Start 50 Minute Session", kind: .action) {
                    store.startFocus(minutes: 50)
                },
                DashboardWidgetOption(title: "Start 90 Minute Session", kind: .action) {
                    store.startFocus(minutes: 90)
                },
                DashboardWidgetOption(title: "Reset Timer", kind: .action) { store.reset() },
            ]
        case .agents:
            return [DashboardWidgetOption(title: "Show Quota As", kind: .header)] + UsageDisplayMode.allCases.map { mode in
                DashboardWidgetOption(title: mode.title, kind: .toggle(settings.usageDisplayMode == mode)) {
                    settings.usageDisplayMode = mode
                }
            } + [
                DashboardWidgetOption(title: "Agent Hooks…", kind: .action) {
                    viewModel.requestsHookReview = true
                    NotificationCenter.default.post(name: .nanoOpenSettings, object: SettingsDestination.agents.rawValue)
                },
            ]
        case .weather:
            return [DashboardWidgetOption(title: "Refresh Weather", kind: .action) {
                viewModel.refreshWeather()
            }]
        case .tray:
            let store = viewModel.trayStore
            return [
                DashboardWidgetOption(title: "Tray", kind: .header),
                DashboardWidgetOption(title: "Paste", kind: .action) { store.pasteFromClipboard() },
                DashboardWidgetOption(title: "AirDrop All", kind: .action) { store.sendViaAirDrop() },
                DashboardWidgetOption(
                    title: store.selection.isEmpty ? "Compress All to ZIP" : "Compress Selected to ZIP",
                    kind: .action
                ) { store.compressToZip(store.selectedURLs) },
                DashboardWidgetOption(title: "Clear Tray", kind: .destructive) { store.clear() },
                DashboardWidgetOption(title: "Remove Files After Dragging Out", kind: .toggle(settings.trayRemovesAfterDragOut)) {
                    settings.trayRemovesAfterDragOut.toggle()
                },
                DashboardWidgetOption(title: "Show Count on the Island", kind: .toggle(settings.trayShowsCompactCount)) {
                    settings.trayShowsCompactCount.toggle()
                },
            ]
        default:
            return []
        }
    }

    /// The native menu form, used by the island's right-click.
    static func menuItems(_ sections: [[DashboardWidgetOption]]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { items.append(.separator()) }
            for option in section {
                switch option.kind {
                case .header:
                    items.append(NSMenuItem.sectionHeader(title: option.title))
                case let .toggle(isOn):
                    let item = DashboardOptionMenuItem(option: option)
                    item.state = isOn ? .on : .off
                    items.append(item)
                case .action, .destructive:
                    items.append(DashboardOptionMenuItem(option: option))
                }
            }
        }
        return items
    }
}

/// An NSMenuItem that runs a `DashboardWidgetOption`.
@MainActor
final class DashboardOptionMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(option: DashboardWidgetOption) {
        run = option.perform
        super.init(title: option.title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() {
        run()
    }
}

/// The SwiftUI form, used by the Settings editor's slot picker.
struct DashboardWidgetOptionsView: View {
    let sections: [[DashboardWidgetOption]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(section) { option in
                        switch option.kind {
                        case .header:
                            Text(option.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        case let .toggle(isOn):
                            Toggle(option.title, isOn: Binding(get: { isOn }, set: { _ in option.perform() }))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                        case .action:
                            Button(option.title) { option.perform() }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        case .destructive:
                            Button(option.title, role: .destructive) { option.perform() }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }
}
