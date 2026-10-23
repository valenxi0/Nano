import AppKit
import Foundation
import OSLog
import SQLite3

/// `log stream --predicate 'subsystem == "com.nanoapp.Nano" AND category == "notifications"'`
let notificationLog = Logger(subsystem: "com.nanoapp.Nano", category: "notifications")

/// One notification macOS recorded in its own Notification Center store.
struct SystemNotificationContent: Equatable, Hashable, Sendable {
    let recordID: Int64
    let uuid: String
    let bundleID: String
    let appName: String
    let title: String?
    let subtitle: String?
    let body: String?
    let deliveredAt: Date
    /// Present for iMessage when the chat could be resolved from Messages.
    var message: SystemNotificationMessageContext? = nil
    /// The app's registered category, used to look up its action buttons.
    var categoryID: String? = nil
    /// Buttons the app registered for this notification, in its order.
    var actions: [SystemNotificationAction] = []
    /// Set when this card stands in for several notifications.
    var summary: SystemNotificationSummary? = nil
    /// The preview was withheld (camera in use). The card shows only the app.
    var previewHidden = false
    /// The app icon's dominant colour, resolved when the card is built.
    var tint: RGB? = nil
    var agentSessionID: String? = nil
    var agentEventID: String? = nil

    struct RGB: Equatable, Hashable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// A row of notifications is not all equal: people first, then everything else.
    enum Tier: Equatable, Sendable {
        case important
        case info

        var duration: TimeInterval {
            self == .important ? 8.0 : 5.0
        }
    }

    static let importantBundleIDs: Set<String> = [
        "com.apple.ical", "com.apple.icalendar", "com.apple.reminders", "com.apple.mail",
        "com.apple.facetime", "com.apple.mobilephone",
    ]

    var tier: Tier {
        if isMessage || isCall || summary != nil { return .important }
        return Self.importantBundleIDs.contains(bundleID.lowercased()) ? .important : .info
    }

    /// True for anything that was not written by macOS itself.
    var isRealRecord: Bool { recordID >= 0 && summary == nil }

    static let messagesBundleIDs: Set<String> = [
        "com.apple.mobilesms", "com.apple.ichat", "com.apple.messages",
    ]

    static let callBundleIDs: Set<String> = [
        "com.apple.facetime", "com.apple.mobilephone", "_system_center_:com.apple.facetime",
    ]

    var isMessage: Bool { Self.messagesBundleIDs.contains(bundleID.lowercased()) }
    var isCall: Bool { Self.callBundleIDs.contains(bundleID.lowercased()) }

    /// Headline for the card: the notification's own title, otherwise the app.
    /// A group iMessage reads "Ada in Family" when the group is known.
    var headline: String {
        if previewHidden { return appName }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? appName : trimmed
        if let group = groupName, !base.isEmpty, base.caseInsensitiveCompare(group) != .orderedSame {
            return "\(base) in \(group)"
        }
        return base
    }

    /// Everything below the headline, flattened to one string.
    var detail: String? {
        if previewHidden { return "New notification" }
        var parts = [subtitle, body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The group name already sits in the headline; do not repeat it.
        if let group = groupName {
            parts.removeAll { $0.caseInsensitiveCompare(group) == .orderedSame }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// The group chat name when Messages knows it and it differs from the sender.
    var groupName: String? {
        guard let message, message.isGroup,
              let name = message.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// Droppy-style relative stamp: "now", "12s", "3m", "2h".
    nonisolated static func timeAgo(from deliveredAt: Date, now: Date = Date()) -> String {
        let seconds = max(Int(now.timeIntervalSince(deliveredAt)), 0)
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }


}

struct SystemNotificationMessageContext: Equatable, Hashable, Sendable {
    /// `iMessage;-;+15551234567` or `iMessage;+;chat123…` for groups.
    let chatGUID: String
    let handle: String?
    let isGroup: Bool
    var groupName: String? = nil
}

/// A button the app registered for its notification category.
struct SystemNotificationAction: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    /// The action expects typed text (a Reply field) rather than a press.
    let wantsText: Bool
    /// The app marked it destructive (Delete, Decline).
    let isDestructive: Bool
}

/// One card standing in for a run of notifications.
struct SystemNotificationSummary: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        /// The storm filter dropped these from one app.
        case storm
        /// Recorded while the Mac was asleep or locked.
        case catchUp
    }

    let kind: Kind
    let count: Int
}

/// Reads the `categories` table: each app's registered categories with the
/// action buttons macOS shows on its banners.
enum SystemNotificationCategoryDecoder {
    nonisolated static func actions(
        in blob: Data,
        categoryID: String,
        localize: (String) -> String?
    ) -> [SystemNotificationAction] {
        guard let categories = try? PropertyListSerialization.propertyList(
            from: blob, options: [], format: nil
        ) as? [[String: Any]] else { return [] }
        guard let category = categories.first(where: { ($0["id"] as? String) == categoryID }),
              let raw = category["acts"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let options = (entry["op"] as? Int) ?? 0
            guard let title = resolveTitle(entry["ti"], localize: localize) else { return nil }
            return SystemNotificationAction(
                id: id,
                title: title,
                // UNNotificationActionOptions: 1 auth, 2 destructive, 4 foreground.
                // Text-input actions carry a placeholder under "tibt"/"tiph".
                wantsText: entry["tibt"] != nil || entry["tiph"] != nil,
                isDestructive: options & 2 != 0
            )
        }
    }

    /// Third-party apps store the title; Apple's store a localisation key
    /// as `[key, key, args]`. Unresolvable keys are humanised.
    nonisolated static func resolveTitle(_ value: Any?, localize: (String) -> String?) -> String? {
        if let title = value as? String { return title.isEmpty ? nil : title }
        guard let parts = value as? [Any], let key = parts.first as? String, !key.isEmpty else { return nil }
        if let localized = localize(key), localized != key, !localized.isEmpty { return localized }
        return humanize(key)
    }

    nonisolated static func humanize(_ key: String) -> String? {
        var stem = key
        for suffix in ["NotificationActionTitle", "ActionTitle", "Action", "Button", "Title"] {
            if stem.hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
        }
        stem = stem.split(separator: ".").last.map(String.init) ?? stem
        stem = stem.replacingOccurrences(of: "_", with: " ")
        var words: [String] = []
        var current = ""
        for ch in stem {
            if ch.isUppercase, !current.isEmpty, !(current.last?.isUppercase ?? false) {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let result = words
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return result.isEmpty ? nil : result
    }
}

enum NotificationStoreAccess: Equatable, Sendable {
    case idle
    case ready
    case needsFullDiskAccess
    case unavailable
}

/// Decodes the binary plist macOS writes into `record.data`.
enum SystemNotificationRecordDecoder {
    nonisolated static func decode(
        data: Data,
        bundleID: String,
        recordID: Int64,
        deliveredDate: Double?,
        appName: String
    ) -> SystemNotificationContent? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }

        let request = root["req"] as? [String: Any] ?? [:]
        let title = cleaned(request["titl"] as? String)
        let subtitle = cleaned(request["subt"] as? String)
        let body = cleaned(request["body"] as? String, limit: 220)
        guard title != nil || subtitle != nil || body != nil else { return nil }

        let uuid: String
        if let raw = root["uuid"] as? Data, raw.count == 16 {
            uuid = raw.map { String(format: "%02x", $0) }.joined()
        } else if let iden = request["iden"] as? String, !iden.isEmpty {
            uuid = "\(bundleID):\(iden)"
        } else {
            uuid = "\(bundleID):\(recordID)"
        }

        let seconds = (root["date"] as? Double) ?? deliveredDate ?? Date().timeIntervalSinceReferenceDate
        var content = SystemNotificationContent(
            recordID: recordID,
            uuid: uuid,
            bundleID: bundleID,
            appName: appName,
            title: title,
            subtitle: subtitle,
            body: body,
            deliveredAt: Date(timeIntervalSinceReferenceDate: seconds)
        )
        content.agentSessionID = request["session_id"] as? String
        content.agentEventID = request["event_id"] as? String
        content.categoryID = request["cate"] as? String
        return content
    }

    /// Messages sends an object-replacement character for a photo or file.
    nonisolated static let attachmentPlaceholder = "\u{FFFC}"

    nonisolated static func cleaned(_ raw: String?, limit: Int = 120) -> String? {
        guard let raw else { return nil }
        let hadAttachment = raw.contains(attachmentPlaceholder)
        var collapsed = raw
            .replacingOccurrences(of: attachmentPlaceholder, with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if hadAttachment {
            collapsed = collapsed.isEmpty ? "Sent an attachment" : "Attachment · \(collapsed)"
        }
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > limit {
            return String(collapsed.prefix(limit - 1)) + "…"
        }
        return collapsed
    }
}

/// Pure admission rules so the store can be tested without a database.
struct SystemNotificationFilter: Sendable {
    enum Verdict: Equatable, Sendable {
        case show
        case stale
        case duplicate
        case excluded
        case storm
    }

    /// Records older than this at read time are history, not news.
    var maximumAge: TimeInterval = 60
    /// More than `stormLimit` from one app inside `stormWindow` is a storm.
    var stormWindow: TimeInterval = 10
    var stormLimit = 5

    private var seenUUIDs: [String] = []
    private var seenUUIDSet: Set<String> = []
    private var recentByApp: [String: [Date]] = [:]

    init() {}

    mutating func admit(
        _ content: SystemNotificationContent,
        excludedBundleIDs: Set<String>,
        now: Date = Date()
    ) -> Verdict {
        if seenUUIDSet.contains(content.uuid) { return .duplicate }
        rememberUUID(content.uuid)

        let lowered = content.bundleID.lowercased()
        if excludedBundleIDs.contains(where: { $0.lowercased() == lowered }) {
            return .excluded
        }
        if now.timeIntervalSince(content.deliveredAt) > maximumAge {
            return .stale
        }

        var stamps = recentByApp[lowered, default: []]
        stamps.removeAll { now.timeIntervalSince($0) > stormWindow }
        stamps.append(now)
        recentByApp[lowered] = stamps
        if stamps.count > stormLimit { return .storm }

        return .show
    }

    private mutating func rememberUUID(_ uuid: String) {
        seenUUIDs.append(uuid)
        seenUUIDSet.insert(uuid)
        if seenUUIDs.count > 400 {
            let dropped = seenUUIDs.removeFirst()
            seenUUIDSet.remove(dropped)
        }
    }
}

/// Resolves a bundle identifier to the name and icon macOS shows for it.
@MainActor
enum SystemNotificationAppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]
    private static var tints: [String: SystemNotificationContent.RGB?] = [:]

    /// The icon's dominant colour, for a per-app glow. Nil for grey icons.
    static func tint(for bundleID: String) -> SystemNotificationContent.RGB? {
        if let cached = tints[bundleID] { return cached }
        let color = icon(for: bundleID).flatMap(dominantColor).map {
            let rgb = $0.usingColorSpace(.deviceRGB) ?? $0
            return SystemNotificationContent.RGB(
                red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent
            )
        }
        tints[bundleID] = color
        return color
    }

    /// Averages the saturated pixels of a 16×16 downsample. Icons are mostly
    /// one hue on white or black, so this lands on the brand colour.
    nonisolated static func dominantColor(of image: NSImage) -> NSColor? {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        context.flushGraphics()

        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for y in 0..<side {
            for x in 0..<side {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                let saturation = pixel.saturationComponent
                let brightness = pixel.brightnessComponent
                // Ignore near-white and near-black; weight by how colourful the pixel is.
                guard saturation > 0.25, brightness > 0.2 else { continue }
                let w = saturation * brightness
                r += pixel.redComponent * w
                g += pixel.greenComponent * w
                b += pixel.blueComponent * w
                weight += w
            }
        }
        guard weight > 4 else { return nil }
        return NSColor(red: r / weight, green: g / weight, blue: b / weight, alpha: 1)
    }

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let resolved = resolveName(bundleID)
        names[bundleID] = resolved
        return resolved
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = applicationURL(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        icons[bundleID] = icon
        return icon
    }

    static func applicationURL(for bundleID: String) -> URL? {
        let normalized = normalizedBundleID(bundleID)
        if normalized.hasPrefix("_system_center_:") {
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.systempreferences"
            )
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalized)
    }

    nonisolated static func normalizedBundleID(_ bundleID: String) -> String {
        let lowered = bundleID.lowercased()
        if lowered == "com.apple.mobilesms" || lowered == "com.apple.ichat" {
            return "com.apple.MobileSMS"
        }
        if lowered.hasPrefix("_system_center_:") { return lowered }
        return bundleID
    }

    private static func resolveName(_ bundleID: String) -> String {
        let lowered = bundleID.lowercased()
        if SystemNotificationContent.messagesBundleIDs.contains(lowered) { return "Messages" }
        if lowered == "com.apple.facetime" || lowered == "_system_center_:com.apple.facetime" {
            return "FaceTime"
        }
        if lowered == "com.apple.mobilephone" { return "Phone" }
        if lowered.hasPrefix("_system_center_:") {
            let tail = String(bundleID.dropFirst("_system_center_:".count))
            return systemCenterName(tail)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            let candidates = [
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            ]
            if let name = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                return name
            }
            return url.deletingPathExtension().lastPathComponent
        }
        return fallbackName(bundleID)
    }

    nonisolated static func systemCenterName(_ tail: String) -> String {
        let lowered = tail.lowercased()
        if lowered.contains("softwareupdate") { return "Software Update" }
        if lowered.contains("bluetooth") { return "Bluetooth" }
        if lowered.contains("wifi") { return "Wi‑Fi" }
        if lowered.contains("appleaccount") || lowered.contains("accountsd") { return "Apple Account" }
        if lowered.contains("sharingd") { return "AirDrop" }
        if lowered.contains("tmhelper") { return "Time Machine" }
        if lowered.contains("appstore") { return "App Store" }
        if lowered.contains("followup") { return "System" }
        return "System"
    }

    nonisolated static func fallbackName(_ bundleID: String) -> String {
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        guard let first = tail.first else { return bundleID }
        return first.uppercased() + tail.dropFirst()
    }
}

/// Reads the store macOS Notification Center writes for every app.
///
/// There is no public mirroring API. The record table is the user's own
/// notification history on their own Mac; reading it needs Full Disk Access
/// and fails closed without it. Only rows newer than the launch-time frontier
/// are announced, so history never replays.
@MainActor
final class NotificationCenterStore: ObservableObject {
    @Published private(set) var access: NotificationStoreAccess = .idle

    var onNotification: ((SystemNotificationContent) -> Void)?
    var onSkipped: ((SystemNotificationContent, SystemNotificationFilter.Verdict) -> Void)?
    var excludedBundleIDs: Set<String> = []

    private var db: OpaquePointer?
    private var frontier: Int64 = 0
    private var started = false
    private var filter = SystemNotificationFilter()
    private var stream: FSEventStreamRef?
    private var darwinRegistered = false
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var openedPath: String?

    static let darwinName = "com.apple.notificationcenterui.bulletin_added"

    nonisolated static var candidatePaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db"),
            home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db/db"),
        ]
    }

    nonisolated static var storeIsReadable: Bool {
        candidatePaths.contains { url in
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return false }
            close(fd)
            return true
        }
    }

    func start() {
        guard !started else { return }
        started = true
        installLifecycleObservers()
        guard openDatabase() else {
            scheduleRetry()
            return
        }
        beginWatching()
    }

    func stop() {
        started = false
        retryTask?.cancel()
        retryTask = nil
        endWatching()
        closeDatabase()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        access = .idle
    }

    func refresh() {
        guard started else { return }
        if db == nil {
            guard openDatabase() else { return }
            beginWatching()
        }
        drain()
    }

    // MARK: Database

    private func openDatabase() -> Bool {
        closeDatabase()
        var lastError: NotificationStoreAccess = .unavailable
        for url in Self.candidatePaths {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else {
                lastError = .needsFullDiskAccess
                continue
            }
            close(fd)

            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
                sqlite3_close(handle)
                lastError = .unavailable
                continue
            }
            sqlite3_busy_timeout(handle, 250)
            guard let maxID = Self.maxRecordID(handle) else {
                sqlite3_close(handle)
                lastError = .unavailable
                continue
            }
            db = handle
            openedPath = url.path
            frontier = maxID
            access = .ready
            notificationLog.info("Opened notification store at \(url.path, privacy: .public), frontier \(maxID)")
            return true
        }
        access = lastError
        notificationLog.error("Notification store unavailable: \(String(describing: lastError), privacy: .public)")
        return false
    }

    private func closeDatabase() {
        if let db { sqlite3_close(db) }
        db = nil
        openedPath = nil
    }

    private nonisolated static func maxRecordID(_ db: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rec_id), 0) FROM record", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private struct RawRecord {
        let recordID: Int64
        let appID: Int64
        let bundleID: String
        let data: Data
        let deliveredDate: Double?
    }

    /// Category blobs are keyed by app id and change only when an app
    /// re-registers, so one read per app per session is enough.
    private var categoryBlobs: [Int64: Data?] = [:]

    private nonisolated static func categoryBlob(appID: Int64, in db: OpaquePointer) -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT categories FROM categories WHERE app_id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, appID)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func actions(for content: SystemNotificationContent, appID: Int64) -> [SystemNotificationAction] {
        guard let db, let categoryID = content.categoryID, !categoryID.isEmpty else { return [] }
        let blob: Data?
        if let cached = categoryBlobs[appID] {
            blob = cached
        } else {
            blob = Self.categoryBlob(appID: appID, in: db)
            categoryBlobs[appID] = blob
        }
        guard let blob else { return [] }
        let bundle = SystemNotificationAppInfo.applicationURL(for: content.bundleID).flatMap(Bundle.init(url:))
        return SystemNotificationCategoryDecoder.actions(in: blob, categoryID: categoryID) { key in
            guard let bundle else { return nil }
            let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
            return value == "\u{0}" ? nil : value
        }
    }

    private nonisolated static func records(after frontier: Int64, in db: OpaquePointer) -> [RawRecord]? {
        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date, r.app_id
        FROM record r
        LEFT JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ?
        ORDER BY r.rec_id ASC
        LIMIT 40
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, frontier)

        var rows: [RawRecord] = []
        while true {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                if step == SQLITE_DONE { break }
                return nil
            }
            let recordID = sqlite3_column_int64(statement, 0)
            let bundleID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var data = Data()
            if let bytes = sqlite3_column_blob(statement, 2) {
                let count = Int(sqlite3_column_bytes(statement, 2))
                data = Data(bytes: bytes, count: count)
            }
            let delivered = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 3)
            let appID = sqlite3_column_int64(statement, 4)
            rows.append(RawRecord(
                recordID: recordID, appID: appID, bundleID: bundleID, data: data, deliveredDate: delivered
            ))
        }
        return rows
    }

    private func drain() {
        guard let db else { return }
        guard let rows = Self.records(after: frontier, in: db) else {
            // A wedged or replaced database. Rebuild on the next tick.
            closeDatabase()
            scheduleRetry()
            return
        }
        guard !rows.isEmpty else { return }
        let now = Date()
        for row in rows {
            frontier = max(frontier, row.recordID)
            guard !row.bundleID.isEmpty, !row.data.isEmpty else { continue }
            let ownBundle = Bundle.main.bundleIdentifier ?? ""
            if !ownBundle.isEmpty, row.bundleID.caseInsensitiveCompare(ownBundle) == .orderedSame {
                continue
            }
            let appName = SystemNotificationAppInfo.name(for: row.bundleID)
            guard var content = SystemNotificationRecordDecoder.decode(
                data: row.data,
                bundleID: row.bundleID,
                recordID: row.recordID,
                deliveredDate: row.deliveredDate,
                appName: appName
            ) else { continue }
            content.actions = actions(for: content, appID: row.appID)

            let verdict = filter.admit(content, excludedBundleIDs: excludedBundleIDs, now: now)
            notificationLog.info(
                "record \(row.recordID) \(row.bundleID, privacy: .public) \(String(describing: verdict), privacy: .public) \(content.headline, privacy: .private)"
            )
            if verdict == .show {
                onNotification?(content)
            } else {
                onSkipped?(content, verdict)
            }
        }
    }

    // MARK: Triggers

    private func beginWatching() {
        startFileWatch()
        registerDarwin()
        startPolling()
    }

    private func endWatching() {
        stopFileWatch()
        unregisterDarwin()
        pollTask?.cancel()
        pollTask = nil
    }

    private func startFileWatch() {
        guard stream == nil, let openedPath else { return }
        let directory = URL(fileURLWithPath: openedPath).deletingLastPathComponent().path as CFString
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let store = Unmanaged<NotificationCenterStore>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in store.drain() }
            },
            &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
    }

    private func stopFileWatch() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func registerDarwin() {
        guard !darwinRegistered else { return }
        darwinRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let store = Unmanaged<NotificationCenterStore>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in store.drain() }
            },
            Self.darwinName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterDarwin() {
        guard darwinRegistered else { return }
        darwinRegistered = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(Self.darwinName as CFString),
            nil
        )
    }

    /// Darwin and FSEvents both proved unreliable in isolation on some
    /// systems; a slow poll guarantees nothing waits longer than a few seconds.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.drain()
            }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.started, self.db == nil else { return }
            if self.openDatabase() {
                self.beginWatching()
            } else {
                self.scheduleRetry()
            }
        }
    }

    private func installLifecycleObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.endWatching() }
        })
    }

    /// Sleep can leave the SQLite handle pointing at a checkpointed WAL.
    /// Reopen, keep the frontier, and resume from where we were.
    private func rebuild() {
        guard started else { return }
        let previousFrontier = frontier
        endWatching()
        guard openDatabase() else {
            scheduleRetry()
            return
        }
        // Anything recorded while asleep is filtered as stale; anything that
        // landed between wake and reopen still gets announced.
        frontier = previousFrontier
        beginWatching()
        drain()
    }
}
