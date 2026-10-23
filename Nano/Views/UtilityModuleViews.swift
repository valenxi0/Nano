import AppKit
import CoreLocation
import SwiftUI


private let nanoCalendarAccent = Color(red: 0.45, green: 0.52, blue: 1.0)

/// The island's Calendar. Month shows a month and the chosen day; Week shows
/// seven days and the chosen day as a timeline. Right-click switches.
struct CalendarModuleView: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var settings: NanoSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate = Date()

    var body: some View {
        Group {
            if service.hasFullAccess {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Group {
                        switch settings.calendarLayout {
                        case .month:
                            CalendarMonthLayout(service: service, selectedDate: $selectedDate, now: context.date)
                        case .week:
                            CalendarWeekLayout(service: service, selectedDate: $selectedDate, now: context.date)
                        }
                    }
                    .transition(.opacity)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: settings.calendarLayout)
                .help("Right-click to switch between Month and Week")
            } else {
                calendarPermission
            }
        }
        .overlay {
            if service.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            service.hiddenCalendarTitles = settings.hiddenCalendars
            service.activate()
        }
    }

    private var calendarPermission: some View {
        NanoPermissionPrompt(
            title: "Calendar access",
            message: calendarPermissionMessage,
            symbol: "calendar",
            buttonTitle: service.authorizationStatus == .notDetermined
                ? "Allow Calendar"
                : "Open System Settings",
            isLoading: service.isLoading
        ) {
            if service.authorizationStatus == .notDetermined {
                service.requestAccess()
            } else {
                openNanoPrivacyPane("Privacy_Calendars")
            }
        }
    }

    private var calendarPermissionMessage: String {
        if let errorMessage = service.errorMessage {
            return errorMessage
        }

        return switch service.authorizationStatus {
        case .notDetermined:
            "Nano reads event titles and times locally. Connected Google calendars appear through Apple Calendar."
        case .denied:
            "Calendar access was denied. Enable Nano in Privacy & Security."
        case .restricted:
            "Calendar access is restricted on this Mac. Check Privacy & Security."
        case .writeOnly:
            "Nano has write-only access, which cannot read events. Allow Full Access in Privacy & Security."
        case .fullAccess:
            ""
        @unknown default:
            "Calendar access is unavailable. Check Privacy & Security."
        }
    }
}

// MARK: - Shared pieces

private enum CalendarText {
    static func timeRange(_ event: NanoCalendarEvent) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    /// "Today · Mon, Sep 28", or just the date on other days.
    static func dayTitle(_ date: Date) -> String {
        let label = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return Calendar.current.isDateInToday(date) ? "Today · \(label)" : label
    }
}

private struct CalendarJoinButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(nanoCalendarAccent, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.nanoPress)
        .help("Join the call")
    }
}

/// Holidays and birthdays on a day, as small labels.
private struct CalendarHolidayChips: View {
    let events: [NanoCalendarEvent]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(events.prefix(2)) { event in
                Text(event.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .foregroundStyle(Color(nanoHex: event.calendarColorHex).opacity(0.95))
                    .background(Color(nanoHex: event.calendarColorHex).opacity(0.16), in: Capsule())
            }
        }
    }
}

private struct CalendarNavButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(nanoCalendarAccent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nanoPress)
        .help(label)
        .accessibilityLabel(label)
    }
}

private func calendarDots(_ events: [NanoCalendarEvent]) -> [Color] {
    var seen: [String] = []
    for event in events where !seen.contains(event.calendarColorHex) {
        seen.append(event.calendarColorHex)
    }
    return seen.prefix(3).map { Color(nanoHex: $0) }
}

// MARK: - Month

private struct CalendarMonthLayout: View {
    @ObservedObject var service: CalendarService
    @Binding var selectedDate: Date
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var isMovingForward = true

    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 16) {
            monthPane
                .frame(width: 300)
            Divider().overlay(.white.opacity(0.10))
            CalendarDayPane(service: service, date: selectedDate, now: now)
        }
    }

    private var monthPane: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 13, weight: .semibold))
                    .id(visibleMonth)
                    .transition(.opacity)
                Spacer(minLength: 0)
                if !calendar.isDate(visibleMonth, equalTo: now, toGranularity: .month) {
                    Button("Today") { jumpToToday() }
                        .buttonStyle(.nanoPress)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(nanoCalendarAccent)
                        .padding(.trailing, 4)
                }
                CalendarNavButton(symbol: "chevron.left", label: "Previous month") { move(by: -1) }
                CalendarNavButton(symbol: "chevron.right", label: "Next month") { move(by: 1) }
            }

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(maxWidth: .infinity)
                }
            }

            ZStack(alignment: .top) {
                grid
                    .id(visibleMonth)
                    .transition(monthTransition)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .overlay {
            NanoScrollCatcher { step in move(by: step) }
        }
        .task(id: visibleMonth) {
            let days = monthDays
            guard let first = days.first, let last = days.last,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
            service.ensureEventsLoaded(for: DateInterval(start: first, end: end))
        }
    }

    private var grid: some View {
        let days = monthDays
        let rows = days.count / 7
        return VStack(spacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(days[row * 7 + column])
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isInMonth = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        let dots = calendarDots(service.events(on: date))

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 3) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 11.5, weight: isToday || isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(
                        isToday ? Color.black : .white.opacity(isInMonth ? 0.86 : 0.24)
                    )
                    .frame(width: 22, height: 22)
                    .background {
                        if isToday {
                            Circle().fill(Color.white)
                        } else if isSelected {
                            Circle().strokeBorder(nanoCalendarAccent, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 2) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
                .opacity(isInMonth ? 1 : 0.4)
            }
            .frame(height: 33)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nanoPress)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }

    private var monthTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isMovingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func move(by offset: Int) {
        guard let month = calendar.date(byAdding: .month, value: offset, to: visibleMonth) else { return }
        isMovingForward = offset > 0
        withAnimation(reduceMotion ? nil : .easeInOut(duration: NanoMotion.monthSlide)) {
            visibleMonth = month
        }
    }

    private func jumpToToday() {
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        isMovingForward = month > visibleMonth
        withAnimation(reduceMotion ? nil : .easeInOut(duration: NanoMotion.monthSlide)) {
            visibleMonth = month
            selectedDate = now
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = max(calendar.firstWeekday - 1, 0)
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Whole weeks covering the month.
    private var monthDays: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: visibleMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let rows = Int((Double(leading + range.count) / 7).rounded(.up))
        guard let start = calendar.date(byAdding: .day, value: -leading, to: visibleMonth) else { return [] }
        return (0..<(rows * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

/// The chosen day as rows. When the day runs out, what comes next follows,
/// so an empty day never ends at "Nothing scheduled".
private struct CalendarDayPane: View {
    @ObservedObject var service: CalendarService
    let date: Date
    let now: Date

    private var dayEvents: [NanoCalendarEvent] {
        service.events(on: date).filter { !$0.isHoliday }
    }

    private var holidays: [NanoCalendarEvent] {
        service.events(on: date).filter(\.isHoliday)
    }

    /// A few events after the chosen day, holidays left out.
    private var nextEvents: [NanoCalendarEvent] {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date
        let from = max(dayEnd, now)
        return Array(service.events.filter { !$0.isHoliday && $0.startDate >= from }.prefix(max(2, 4 - dayEvents.count)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    sectionTitle(CalendarText.dayTitle(date))
                    CalendarHolidayChips(events: holidays)
                }
                if dayEvents.isEmpty {
                    Text(holidays.isEmpty ? "Nothing scheduled" : "No events")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.vertical, 4)
                } else {
                    ForEach(dayEvents) { event in
                        row(event, detail: detail(for: event), tinted: true)
                    }
                }
                if !nextEvents.isEmpty {
                    sectionTitle("Next").padding(.top, 8)
                    ForEach(nextEvents) { event in
                        row(
                            event,
                            detail: NanoEventTiming.listLine(start: event.startDate, isAllDay: event.isAllDay, now: now),
                            tinted: false
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detail(for event: NanoCalendarEvent) -> String {
        let range = CalendarText.timeRange(event)
        guard !event.isAllDay, Calendar.current.isDate(event.startDate, inSameDayAs: now) else { return range }
        let when = NanoEventTiming.countdown(start: event.startDate, isAllDay: false, now: now)
        return event.endDate <= now ? range : "\(range) · \(when)"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.36))
    }

    private func row(_ event: NanoCalendarEvent, detail: String, tinted: Bool) -> some View {
        let color = Color(nanoHex: event.calendarColorHex)
        let isOver = event.endDate <= now
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tinted ? color.opacity(0.9) : .white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let url = event.joinURL, !isOver {
                CalendarJoinButton(url: url)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tinted ? color.opacity(0.13) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(isOver ? 0.5 : 1)
    }
}

// MARK: - Week

private struct CalendarWeekLayout: View {
    @ObservedObject var service: CalendarService
    @Binding var selectedDate: Date
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()

    private let calendar = Calendar.current

    private var days: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 2) {
                Text(weekTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if !calendar.isDate(weekStart, equalTo: now, toGranularity: .weekOfYear) {
                    Button("Today") { jumpToToday() }
                        .buttonStyle(.nanoPress)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(nanoCalendarAccent)
                        .padding(.trailing, 4)
                }
                CalendarNavButton(symbol: "chevron.left", label: "Previous week") { move(by: -1) }
                CalendarNavButton(symbol: "chevron.right", label: "Next week") { move(by: 1) }
            }

            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    dayTile(day)
                }
            }
            .overlay {
                NanoScrollCatcher { step in move(by: step) }
            }

            CalendarDayTimeline(service: service, date: selectedDate, now: now)
        }
        .task(id: weekStart) {
            guard let end = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return }
            service.ensureEventsLoaded(for: DateInterval(start: weekStart, end: end))
        }
    }

    private var weekTitle: String {
        guard let last = days.last, let first = days.first else { return "" }
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
    }

    private func dayTile(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let dots = calendarDots(service.events(on: day))
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { selectedDate = day }
        } label: {
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.5) : .white.opacity(0.36))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.black : (isToday ? nanoCalendarAccent : .white.opacity(0.9)))
                HStack(spacing: 3) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.white : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.nanoPress)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private func move(by weeks: Int) {
        guard let start = calendar.date(byAdding: .weekOfYear, value: weeks, to: weekStart),
              let selected = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDate) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            weekStart = start
            selectedDate = selected
        }
    }

    private func jumpToToday() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            selectedDate = now
        }
    }
}

/// One day laid out on an hour axis, so free time shows as space.
private struct CalendarDayTimeline: View {
    @ObservedObject var service: CalendarService
    let date: Date
    let now: Date

    private let calendar = Calendar.current

    /// Today, only what hasn't finished: the timeline starts from now.
    private var timed: [NanoCalendarEvent] {
        service.events(on: date)
            .filter { !$0.isAllDay && !$0.isHoliday && (!isToday || $0.endDate > now) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var allDay: [NanoCalendarEvent] {
        service.events(on: date).filter { $0.isAllDay || $0.isHoliday }
    }

    private var isToday: Bool { calendar.isDate(date, inSameDayAs: now) }

    var body: some View {
        let hours = NanoTimelineLayout.hourRange(
            events: timed.map { ($0.startDate, $0.endDate) },
            day: date,
            now: isToday ? now : nil,
            calendar: calendar
        )
        VStack(alignment: .leading, spacing: 6) {
            if !allDay.isEmpty {
                HStack(spacing: 6) {
                    Text("ALL DAY")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                    CalendarHolidayChips(events: allDay)
                }
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let hourWidth = width / CGFloat(hours.count)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(hours, id: \.self) { hour in
                            VStack(alignment: .leading) {
                                Text(hourLabel(hour))
                                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.32))
                                    .padding(.leading, 4)
                                    .padding(.top, 4)
                                Spacer(minLength: 0)
                            }
                            .frame(width: hourWidth, alignment: .leading)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                            }
                        }
                    }

                    let spans = timed.map { ($0.startDate, $0.endDate) }
                    let lanes = NanoTimelineLayout.lanes(spans)
                    let laneCount = max(lanes.max() ?? 0, 0) + 1
                    let top: CGFloat = 20
                    let laneHeight = (geometry.size.height - top - 8) / CGFloat(laneCount)
                    ForEach(Array(timed.enumerated()), id: \.element.id) { index, event in
                        let x = position(event.startDate, hours: hours, width: width)
                        let end = position(event.endDate, hours: hours, width: width)
                        // A short event's name runs on into the free time after it.
                        let next = NanoTimelineLayout.nextStart(after: index, in: spans, lanes: lanes)
                            .map { position($0, hours: hours, width: width) } ?? width
                        block(
                            event,
                            width: max(end - x - 3, 8),
                            labelWidth: max(end - x - 3, next - x - 10),
                            height: min(laneHeight - 4, 64)
                        )
                        .offset(x: x + 2, y: top + CGFloat(lanes[index]) * laneHeight)
                    }

                    if isToday, hours.first.map({ now >= hourDate($0) }) == true,
                       now < hourDate((hours.last ?? 23) + 1) {
                        let x = position(now, hours: hours, width: width)
                        Rectangle()
                            .fill(Color(red: 1, green: 0.35, blue: 0.37))
                            .frame(width: 2)
                            .offset(x: x - 1)
                        Circle()
                            .fill(Color(red: 1, green: 0.35, blue: 0.37))
                            .frame(width: 7, height: 7)
                            .offset(x: x - 3.5, y: -2)
                    }

                    if timed.isEmpty {
                        Text(isToday ? "Nothing else today" : "Nothing scheduled")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: width, height: geometry.size.height)
                    }
                }
            }
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func block(_ event: NanoCalendarEvent, width: CGFloat, labelWidth: CGFloat, height: CGFloat) -> some View {
        let color = Color(nanoHex: event.calendarColorHex)
        let isOver = event.endDate <= now
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.22))
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, style: .continuous)
                        .fill(color)
                        .frame(width: 3)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(height > 40 ? 2 : 1)
                if height > 34 {
                    Text(CalendarText.timeRange(event))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if let url = event.joinURL, !isOver, labelWidth > 60, height > 52 {
                    CalendarJoinButton(url: url)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: max(labelWidth, 30), alignment: .topLeading)
        }
        .frame(width: max(width, labelWidth), height: height, alignment: .topLeading)
        .opacity(isOver ? 0.5 : 1)
        .help("\(event.title), \(CalendarText.timeRange(event))")
    }

    private func hourDate(_ hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: calendar.startOfDay(for: date)) ?? date
    }

    private func position(_ time: Date, hours: [Int], width: CGFloat) -> CGFloat {
        guard let first = hours.first else { return 0 }
        let start = hourDate(first)
        let span = CGFloat(hours.count) * 3600
        let offset = CGFloat(time.timeIntervalSince(start))
        return min(max(offset / span, 0), 1) * width
    }

    private func hourLabel(_ hour: Int) -> String {
        hourDate(hour).formatted(.dateTime.hour())
    }
}

/// The timeline's arithmetic, kept apart from the view so it can be tested.
enum NanoTimelineLayout {
    /// The hours to draw: an hour either side of the day's events, from now
    /// on today, 9 to 5 on an empty day, and at least six hours so short
    /// events keep some width.
    static func hourRange(
        events: [(start: Date, end: Date)],
        day: Date,
        now: Date?,
        calendar: Calendar = .current
    ) -> [Int] {
        let dayStart = calendar.startOfDay(for: day)
        func hour(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 3600 }
        var first = events.map { hour($0.start).rounded(.down) }.min()
        var last = events.map { hour($0.end).rounded(.up) }.max()
        if let now {
            first = min(first ?? .infinity, hour(now).rounded(.down))
            last = max(last ?? 0, hour(now).rounded(.up))
        } else if let start = first {
            first = start - 1
        }
        var lower = first ?? 9
        var upper = (last ?? 17) + (last == nil ? 0 : 1)
        if upper - lower < 6 { upper = lower + 6 }
        if upper > 24 { lower = max(0, lower - (upper - 24)); upper = 24 }
        lower = max(lower, 0)
        return Array(Int(lower)..<Int(upper))
    }

    /// When the next event in the same lane starts, which bounds how far a label may run.
    static func nextStart(after index: Int, in events: [(start: Date, end: Date)], lanes: [Int]) -> Date? {
        events.indices
            .filter { $0 != index && lanes[$0] == lanes[index] && events[$0].start >= events[index].end }
            .map { events[$0].start }
            .min()
    }

    /// A lane for each event so overlapping ones stack instead of covering each other.
    static func lanes(_ events: [(start: Date, end: Date)]) -> [Int] {
        var laneEnds: [Date] = []
        return events.map { event in
            if let free = laneEnds.firstIndex(where: { $0 <= event.start }) {
                laneEnds[free] = event.end
                return free
            }
            laneEnds.append(event.end)
            return laneEnds.count - 1
        }
    }
}


struct CameraModuleView: View {
    @ObservedObject var service: CameraService

    private var cameraPicker: some View {
        Menu {
            ForEach(service.devices) { device in
                Button {
                    service.select(device)
                } label: {
                    if device.id == service.selectedDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 9))
                Text(selectedName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var selectedName: String {
        service.devices.first { $0.id == service.selectedDeviceID }?.name ?? "Camera"
    }

    private func cameraFailure(_ message: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 17))
            Text(message)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
            Button("Try Again", action: service.activate)
                .buttonStyle(.nanoPress)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(16)
    }

    var body: some View {
        switch service.availability {
        case .authorized:
            ZStack(alignment: .bottomTrailing) {
                CameraPreview(previewLayer: service.previewLayer)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if let errorMessage = service.errorMessage {
                            cameraFailure(errorMessage)
                        } else if !service.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                if !service.devices.isEmpty {
                    cameraPicker
                        .padding(10)
                }
            }
            .onAppear(perform: service.refreshDevices)
        case .notDetermined:
            NanoPermissionPrompt(
                title: "Camera preview",
                message: "Video stays in memory and is never recorded or uploaded.",
                symbol: "camera.fill",
                buttonTitle: "Allow Camera",
                isLoading: false,
                action: service.requestAccess
            )
        case .denied, .restricted:
            NanoPermissionPrompt(
                title: "Camera access is off",
                message: "Enable Nano under Privacy & Security → Camera.",
                symbol: "camera.fill",
                buttonTitle: "Open System Settings",
                isLoading: false
            ) {
                openNanoPrivacyPane("Privacy_Camera")
            }
        case .unavailable:
            ContentUnavailableView(
                "No camera available",
                systemImage: "video.slash.fill",
                description: Text(
                    service.errorMessage ?? "Connect a camera and reopen this module."
                )
            )
        }
    }
}

struct WeatherModuleView: View {
    @ObservedObject var service: NanoWeatherService
    @ObservedObject var settings: NanoSettings

    @State private var showsSearch = false
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var isSearching = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = service.snapshot {
                forecast(snapshot)
            } else {
                placeholder
            }

            Spacer(minLength: 0)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: populateFields)
    }

    private func forecast(_ snapshot: NanoWeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.placeName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(NanoTemperature.text(snapshot.temperature))
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: NanoTemperature.text(snapshot.temperature))
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    Image(systemName: snapshot.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 26))
                    Text(snapshot.condition)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let high = snapshot.high, let low = snapshot.low {
                        Text(NanoTemperature.highLow(high: high, low: low))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            if !snapshot.hours.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(snapshot.hours.enumerated()), id: \.element.id) { index, hour in
                        VStack(spacing: 7) {
                            Text(index == 0 ? "Now" : hour.date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                                .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? .white : .white.opacity(0.55))
                            Image(systemName: hour.symbolName)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 15))
                            Text(NanoTemperature.text(hour.temperature))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(service.isLoading ? (hasSavedCity ? "Loading the forecast…" : "Finding your location…") : "Weather")
                .font(.system(size: 17, weight: .semibold))
            Text(service.errorMessage ?? (hasSavedCity
                ? settings.weatherLocationName
                : "Nano reads your current location for local conditions."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)

            if hasSavedCity {
                // A saved city needs no location access: retry that city
                // rather than switching to this Mac's location.
                if !service.isLoading {
                    Button("Try Again") {
                        service.refresh(latitude: settings.weatherLatitude, longitude: settings.weatherLongitude)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else if service.authorizationStatus == .denied || service.authorizationStatus == .restricted {
                Button("Open Privacy Settings") {
                    openNanoPrivacyPane("Privacy_LocationServices")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if !service.isLoading {
                Button("Use Current Location") {
                    settings.weatherUsesCurrentLocation = true
                    service.refreshCurrentLocation(force: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var hasSavedCity: Bool {
        settings.weatherHasLocation && !settings.weatherUsesCurrentLocation
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSearch {
                searchField

                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { place in
                            Button { select(place) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(place.name)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(place.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.nanoPress)
                        }
                    }
                    .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            HStack(spacing: 10) {
                Button(showsSearch ? "Use current location" : "Choose a location") {
                    if showsSearch {
                        settings.weatherUsesCurrentLocation = true
                        service.refreshCurrentLocation(force: true)
                        results = []
                        query = ""
                    }
                    showsSearch.toggle()
                }
                .buttonStyle(.nanoPress)
                .foregroundStyle(.white.opacity(0.5))

                if let message = validationMessage {
                    Text(message)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                Spacer()

                if service.isLoading {
                    ProgressView().controlSize(.small)
                }

                Link(
                    service.snapshot?.source.attribution ?? "Weather data from MET Norway",
                    destination: service.snapshot?.source.attributionURL
                        ?? URL(string: "https://api.met.no/doc/TermsOfService")!
                )
                .foregroundStyle(.white.opacity(0.35))
            }
            .font(.system(size: 10))
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))

            TextField("Search a city or ZIP code", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { Task { await runSearch() } }

            if isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 0.6)
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        validationMessage = nil
        let placemarks = (try? await CLGeocoder().geocodeAddressString(trimmed)) ?? []
        isSearching = false

        results = placemarks.prefix(3).compactMap { placemark in
            guard let coordinate = placemark.location?.coordinate else { return nil }
            let name = placemark.locality ?? placemark.name ?? "Location"
            let detail = [placemark.administrativeArea, placemark.country]
                .compactMap { $0 }
                .joined(separator: ", ")
            return WeatherPlace(
                name: name,
                detail: detail,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }

        if results.isEmpty {
            validationMessage = "No places matched that search."
        }
    }

    private func select(_ place: WeatherPlace) {
        settings.setWeatherLocation(
            name: place.name,
            latitude: place.latitude,
            longitude: place.longitude
        )
        service.refresh(latitude: place.latitude, longitude: place.longitude)
        results = []
        query = place.name
    }

    private func populateFields() {
        query = settings.weatherLocationName
        showsSearch = !settings.weatherUsesCurrentLocation && settings.weatherHasLocation
    }

}

private struct NanoPermissionPrompt: View {
    let title: String
    let message: String
    let symbol: String
    let buttonTitle: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 27))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
        }
    }
}

private func openNanoPrivacyPane(_ anchor: String) {
    NanoPrivacySettings.open(anchor)
}

private extension Color {
    init(nanoHex: String) {
        let value = nanoHex.trimmingCharacters(
            in: CharacterSet(charactersIn: "#")
        )
        let number = UInt64(value, radix: 16) ?? 0xFF453A
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

struct WeatherPlace: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
}
