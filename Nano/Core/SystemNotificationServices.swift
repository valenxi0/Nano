import AppKit
import ApplicationServices
import Contacts
import CoreMediaIO
import Foundation
import SQLite3

/// Finds the Messages chat behind an iMessage notification.
///
/// The Notification Center record carries the sender's display name, not
/// their handle. Messages' own `chat.db` has the handle and the chat GUID,
/// which is what an AppleScript reply needs. Same Full Disk Access grant.
enum MessagesChatResolver {
    struct Match: Equatable, Sendable {
        let chatGUID: String
        let handle: String?
        let isGroup: Bool
        let text: String?
        let date: Date
        var groupName: String? = nil
        }

    nonisolated static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    /// Matches by time first, words second. A body that Messages truncated
    /// with an ellipsis still starts the same way as the stored text.
    nonisolated static func unambiguousMatch(
        from candidates: [Match],
        deliveredAt: Date,
        body: String?,
        tolerance: TimeInterval = 45
    ) -> Match? {
        let inWindow = candidates.filter { abs($0.date.timeIntervalSince(deliveredAt)) <= tolerance }
        let needle = (body ?? "").replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let worded = needle.isEmpty ? [] : inWindow.filter {
            guard let text = $0.text?.lowercased(), !text.isEmpty else { return false }
            return text.hasPrefix(needle) || needle.hasPrefix(text.prefix(24))
        }
        let pool = worded.isEmpty ? inWindow : worded
        guard let first = pool.first, pool.allSatisfy({ $0.chatGUID == first.chatGUID }) else { return nil }
        return first
    }

    nonisolated static func resolve(
        deliveredAt: Date,
        body: String?
    ) -> SystemNotificationMessageContext? {
        guard let match = unambiguousMatch(from: recentInbound(limit: 8), deliveredAt: deliveredAt, body: body) else {
            return nil
        }
        return SystemNotificationMessageContext(
            chatGUID: match.chatGUID,
            handle: match.handle,
            isGroup: match.isGroup,
            groupName: match.isGroup ? match.groupName : nil
        )
    }

    nonisolated static func recentInbound(limit: Int) -> [Match] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let sql = """
        SELECT c.guid, c.style, COALESCE(h.uncanonicalized_id, h.id), m.text, m.date, c.display_name
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.is_from_me = 0
        ORDER BY m.ROWID DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var matches: [Match] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidC = sqlite3_column_text(statement, 0) else { continue }
            let style = sqlite3_column_int(statement, 1)
            let handle = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let text = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let rawDate = sqlite3_column_int64(statement, 4)
            let displayName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            matches.append(Match(
                chatGUID: String(cString: guidC),
                handle: handle,
                isGroup: style == 43,
                text: text,
                date: messagesDate(rawDate),
                groupName: (displayName?.isEmpty ?? true) ? nil : displayName
            ))
        }
        return matches
    }

    /// Messages stores nanoseconds since 2001 on modern systems, seconds on old ones.
    nonisolated static func messagesDate(_ raw: Int64) -> Date {
        let seconds = raw > 10_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

/// Sends an iMessage reply through the Messages app.
///
/// Uses Apple Events, which macOS gates behind an Automation prompt the
/// first time. Messages keeps the thread, the read state, and the history.
@MainActor
enum MessagesReplySender {
    enum Failure: Error, Equatable {
        case emptyText
        case scriptError(String)
    }

    nonisolated static func script(chatGUID: String, text: String) -> String {
        """
        tell application "Messages"
            set targetChat to a reference to chat id "\(escaped(chatGUID))"
            send "\(escaped(text))" to targetChat
        end tell
        """
    }

    nonisolated static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func send(_ text: String, to chatGUID: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyText }
        let source = script(chatGUID: chatGUID, text: trimmed)
        let outcome: Result<Void, Failure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                script?.executeAndReturnError(&error)
                if let error {
                    let message = (error[NSAppleScript.errorMessage] as? String)
                        ?? (error[NSAppleScript.errorBriefMessage] as? String)
                        ?? "Messages did not accept the reply."
                    continuation.resume(returning: .failure(.scriptError(message)))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
        try outcome.get()
    }
}

/// Looks up the sender's contact photo for iMessage cards.
@MainActor
final class ContactPhotoProvider: ObservableObject {
    @Published private(set) var authorization: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    private let store = CNContactStore()
    private var cache: [String: NSImage?] = [:]

    func refreshAuthorization() {
        authorization = CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() {
        refreshAuthorization()
        guard authorization == .notDetermined else { return }
        store.requestAccess(for: .contacts) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    notificationLog.error("contacts access \(error.localizedDescription, privacy: .public)")
                } else {
                    notificationLog.info("contacts access granted=\(granted)")
                }
                self?.refreshAuthorization()
            }
        }
    }

    /// Cached, keyed by handle. `nil` in the cache means "asked, no photo".
    func photo(for handle: String) async -> NSImage? {
        let key = handle.lowercased()
        if let cached = cache[key] { return cached }
        guard authorization == .authorized else { return nil }
        let image: NSImage? = await Task.detached(priority: .utility) {
            Self.lookup(handle: handle, in: CNContactStore())
        }.value
        cache[key] = image
        return image
    }

    nonisolated static func predicate(for handle: String) -> NSPredicate? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("@") {
            return CNContact.predicateForContacts(matchingEmailAddress: trimmed)
        }
        return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: trimmed))
    }

    private nonisolated static func lookup(handle: String, in store: CNContactStore) -> NSImage? {
        guard let predicate = predicate(for: handle) else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
        ]
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
              let data = contacts.compactMap(\.thumbnailImageData).first
        else { return nil }
        return NSImage(data: data)
    }
}

/// Closes the macOS banner for an alert the island is already showing.
///
/// Notification Center exposes each banner through Accessibility. The
/// element whose text matches the alert gets its close action performed.
/// Needs Accessibility trust, which Nano already asks for.
@MainActor
final class NativeBannerSuppressor: ObservableObject {
    static let notificationCenterBundleID = "com.apple.notificationcenterui"
    enum Observation: Equatable { case unavailable, absent, individual, grouped }
    enum Outcome: String { case verified, notObserved, grouped, unavailable, failed }
    struct Issue: Identifiable, Equatable {
        let bundleID: String
        let appName: String
        let outcome: Outcome
        var id: String { bundleID }
    }

    @Published private(set) var issues: [Issue] = []
    @Published private(set) var setupInProgress = false
    @Published private(set) var setupStatus: String?
    var onOutcome: ((SystemNotificationContent, Outcome) -> Void)?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let observe: (SystemNotificationContent) -> Observation
    private let dismiss: (SystemNotificationContent) -> Bool
    private let retryDelays: [TimeInterval]

    init(observe: ((SystemNotificationContent) -> Observation)? = nil,
         dismiss: ((SystemNotificationContent) -> Bool)? = nil,
         retryDelays: [TimeInterval] = [0, 0.08, 0.16, 0.3, 0.5, 0.8]) {
        self.observe = observe ?? { Self.findBanner(matching: $0).observation }
        self.dismiss = dismiss ?? { Self.closeBanner(matching: $0) }
        self.retryDelays = retryDelays
    }

    private func key(for content: SystemNotificationContent) -> String {
        NotificationIdentity.recordID(content.uuid) ?? NotificationIdentity.words(content)
    }

    func suppress(_ content: SystemNotificationContent) {
        guard !content.isCall else { return }
        let key = key(for: content)
        guard inFlight[key] == nil else { return }
        inFlight[key] = Task { [weak self] in
            guard let self else { return }
            var observed = false
            var outcome: Outcome = .notObserved
            for delay in retryDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                switch observe(content) {
                case .unavailable:
                    outcome = .unavailable
                    continue
                case .absent:
                    if observed { outcome = .verified }
                case .grouped:
                    outcome = .grouped
                case .individual:
                    observed = true
                    outcome = .failed
                    _ = dismiss(content)
                    continue
                }
                if outcome == .verified || outcome == .grouped { break }
            }
            if observed, outcome != .grouped, observe(content) == .absent { outcome = .verified }
            guard !Task.isCancelled else { return }
            inFlight[key] = nil
            if outcome == .verified {
                issues.removeAll { $0.bundleID == content.bundleID }
            } else if [.grouped, .unavailable, .failed].contains(outcome) {
                let issue = Issue(bundleID: content.bundleID, appName: content.appName, outcome: outcome)
                issues.removeAll { $0.id == issue.id }
                issues.append(issue)
            }
            notificationLog.info("native banner \(content.bundleID, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
            onOutcome?(content, outcome)
        }
    }

    func cancelAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    func openSettings(for issue: Issue) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// User-initiated fallback for layouts macOS cannot dismiss individually.
    /// The visible pane, app name and existing delivery settings must all agree
    /// before touching the Desktop checkbox. No preference database is edited.
    func configureDesktopBanners(for issue: Issue, storeReady: Bool) async {
        guard !setupInProgress else { return }
        guard storeReady, AXIsProcessTrusted(), issue.bundleID != "ax.unknown" else {
            setupStatus = "Nano needs notification store access, Accessibility, and an identified app before automatic setup."
            return
        }
        setupInProgress = true
        setupStatus = "Opening notification settings for \(issue.appName)…"
        defer { setupInProgress = false }
        openSettings(for: issue)
        var selectedApp = false
        var pressedDesktop = false
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                let title = Self.attribute(window, kAXTitleAttribute) as? String ?? ""
                if title == issue.appName, selectedApp {
                    guard let desktop = (Self.findElement(in: window, identifier: "notification-presence-dektop") ?? Self.findElement(in: window, identifier: "notification-presence-desktop")),
                          let allow = Self.findElement(in: window, identifier: "allow-notifications"),
                          let center = Self.findElement(in: window, identifier: "notification-presence-notificationCenter"),
                          Self.checked(allow) == true, Self.checked(center) == true else {
                        setupStatus = "Setup stopped because this app's notification delivery settings could not be verified."
                        return
                    }
                    if Self.checked(desktop) == false {
                        issues.removeAll { $0.id == issue.id }
                        setupStatus = "Desktop banners are off for \(issue.appName). Notifications remain enabled for Nano to receive."
                        return
                    }
                    if Self.checked(desktop) == true, !pressedDesktop {
                        pressedDesktop = true
                        _ = AXUIElementPerformAction(desktop, kAXPressAction as CFString)
                    }
                } else if title == "Notifications", !selectedApp,
                          let button = Self.uniqueAppButton(in: window, appName: issue.appName) {
                    selectedApp = true
                    _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
            }
        }
        setupStatus = "Automatic setup could not verify the app's Desktop setting. You can finish in notification settings."
    }

    private static func checked(_ element: AXUIElement) -> Bool? {
        (attribute(element, kAXValueAttribute) as? NSNumber).map { $0.intValue == 1 }
    }

    private static func findElement(in node: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 18 else { return nil }
        if attribute(node, kAXIdentifierAttribute) as? String == identifier { return node }
        for child in children(node) {
            if let result = findElement(in: child, identifier: identifier, depth: depth + 1) { return result }
        }
        return nil
    }

    private static func uniqueAppButton(in window: AXUIElement, appName: String) -> AXUIElement? {
        var matches: [AXUIElement] = []
        func visit(_ node: AXUIElement, depth: Int) {
            guard depth < 18 else { return }
            if attribute(node, kAXRoleAttribute) as? String == kAXButtonRole {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(node, $0) as? String }
                if labels.contains(where: { $0 == appName || $0.hasPrefix(appName + ",") }) { matches.append(node) }
            }
            for child in children(node) { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return matches.count == 1 ? matches.first : nil
    }

    /// Presses the button titled `title` on the macOS banner for `content`.
    /// Returns false when the banner is gone or has no such button, so the
    /// caller can fall back to opening the app.
    func pressAction(titled title: String, on content: SystemNotificationContent) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let key = key(for: content)
        inFlight[key]?.cancel()
        inFlight[key] = nil
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.notificationCenterBundleID).first
        else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        let wanted = title.lowercased()
        for window in windows {
            for candidate in Self.bannerCandidates(in: window) {
                guard Self.matches(texts: Self.collectTexts(candidate, depth: 0), content: content) else { continue }
                // Banner actions are AX actions on the banner itself, with the
                // button title as their description; older ones are buttons.
                for name in Self.actionNames(candidate) {
                    let description = (Self.AXUIElementCopyActionDescriptionValue(candidate, name) ?? "").lowercased()
                    if description == wanted || name.lowercased() == wanted {
                        if AXUIElementPerformAction(candidate, name as CFString) == .success { return true }
                    }
                }
                if let button = Self.button(titled: wanted, in: candidate, depth: 0),
                   AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                    return true
                }
            }
        }
        return false
    }

    private static func button(titled wanted: String, in node: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 6 else { return nil }
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        if role == kAXButtonRole as String || role == kAXMenuItemRole as String {
            let label = [
                attribute(node, kAXTitleAttribute) as? String,
                attribute(node, kAXDescriptionAttribute) as? String,
            ].compactMap { $0?.lowercased() }
            if label.contains(wanted) { return node }
        }
        for child in children(node) {
            if let hit = button(titled: wanted, in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    nonisolated static func matches(texts: [String], content: SystemNotificationContent) -> Bool {
        if let description = texts.first, description.hasSuffix(", stacked"),
           let appName = description.components(separatedBy: ", ").first,
           content.bundleID != "ax.unknown",
           foldForMatch(appName) != foldForMatch(content.appName) { return false }
        let haystack = foldForMatch(texts.joined(separator: " "))
        guard !haystack.isEmpty else { return false }
        let title = foldForMatch(content.headline)
        guard !title.isEmpty, haystack.contains(title) else { return false }
        if let body = content.body {
            let foldedBody = foldForMatch(body.replacingOccurrences(of: "…", with: ""))
            if !foldedBody.isEmpty {
                return haystack.contains(String(foldedBody.prefix(24)))
            }
        }
        return true
    }

    /// Quotes, dashes, and case differ between the store plist and the AX tree.
    nonisolated static func foldForMatch(_ string: String) -> String {
        string
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "„", with: "\"")
            .replacingOccurrences(of: "«", with: "\"")
            .replacingOccurrences(of: "»", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .lowercased()
    }

    private static func findBanner(matching content: SystemNotificationContent) -> (observation: Observation, element: AXUIElement?) {
        guard AXIsProcessTrusted() else { return (.unavailable, nil) }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).first else {
            return (.absent, nil)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { return (.unavailable, nil) }
        for window in windows {
            let windowTexts = collectTexts(window, depth: 0)
            if GenericNotificationBanner.isNotificationCenterPanel(texts: windowTexts) { continue }
            for candidate in bannerCandidates(in: window) {
                let texts = collectTexts(candidate, depth: 0)
                let candidateID = (attribute(candidate, kAXIdentifierAttribute) as? String).flatMap(NotificationIdentity.recordID)
                let exactID = candidateID != nil && candidateID == NotificationIdentity.recordID(content.uuid)
                guard exactID || matches(texts: texts, content: content) else { continue }
                let actions = actionNames(candidate).compactMap { AXUIElementCopyActionDescriptionValue(candidate, $0) }
                let grouped = isGrouped(texts: texts, actionDescriptions: actions)
                return (grouped ? .grouped : .individual, candidate)
            }
        }
        return (.absent, nil)
    }

    nonisolated static func isGrouped(texts: [String], actionDescriptions: [String]) -> Bool {
        texts.contains { $0.lowercased().hasSuffix(", stacked") }
            || actionDescriptions.contains { $0.lowercased().contains("clear all") }
    }

    private static func closeBanner(matching content: SystemNotificationContent) -> Bool {
        let found = findBanner(matching: content)
        guard found.observation == .individual, let element = found.element else { return false }
        return performClose(on: element)
    }

    /// Banners are the direct groups inside a Notification Center window.
    /// Stacked alerts each get their own group.
    static func bannerCandidates(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 6 else { return }
            let identifier = attribute(element, kAXIdentifierAttribute) as? String
            let actions = actionNames(element).compactMap { AXUIElementCopyActionDescriptionValue(element, $0)?.lowercased() }
            if identifier != nil, actions.contains(where: { ["close", "clear all", "show details", "hide details"].contains($0) }) {
                found.append(element)
                return
            }
            for child in children(element) { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return found.isEmpty ? [window] : found
    }

    nonisolated static func isIndividualDismissAction(name: String, description: String) -> Bool {
        let label = description.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.contains("all"), !name.lowercased().contains("all") else { return false }
        return name == "AXClose" || ["close", "clear", "dismiss", "close notification"].contains(label)
    }

    private static func performClose(on element: AXUIElement) -> Bool {
        let descriptions = actionNames(element).compactMap { AXUIElementCopyActionDescriptionValue(element, $0) }
        guard !isGrouped(texts: collectTexts(element, depth: 0), actionDescriptions: descriptions) else { return false }
        for name in actionNames(element) {
            let description = (AXUIElementCopyActionDescriptionValue(element, name) ?? "").lowercased()
            if isIndividualDismissAction(name: name, description: description) {
                if AXUIElementPerformAction(element, name as CFString) == .success { return true }
            }
        }
        // Older layouts expose a dedicated close button.
        var buttons: [AXUIElement] = []
        func visit(_ node: AXUIElement, depth: Int) {
            guard depth <= 6 else { return }
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole as String {
                let labels = [
                    attribute(node, kAXTitleAttribute) as? String,
                    attribute(node, kAXDescriptionAttribute) as? String,
                ].compactMap { $0 }
                if !labels.contains(where: { $0.lowercased().contains("all") }),
                   labels.contains(where: { isIndividualDismissAction(name: "", description: $0) }) {
                    buttons.append(node)
                }
            }
            for child in children(node) { visit(child, depth: depth + 1) }
        }
        visit(element, depth: 0)
        for button in buttons where AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            return true
        }
        return false
    }

    static func collectTexts(_ element: AXUIElement, depth: Int) -> [String] {
        guard depth <= 7 else { return [] }
        var texts: [String] = []
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = attribute(element, key) as? String, !text.isEmpty { texts.append(text) }
        }
        for child in children(element) {
            texts.append(contentsOf: collectTexts(child, depth: depth + 1))
        }
        return texts
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func AXUIElementCopyActionDescriptionValue(_ element: AXUIElement, _ action: String) -> String? {
        var description: CFString?
        guard AXUIElementCopyActionDescription(element, action as CFString, &description) == .success else {
            return nil
        }
        return description as String?
    }
}

/// Recognises the incoming-call banner from the words on it.
///
/// Calls never reach the Notification Center store, so the only trace of a
/// ringing FaceTime or relayed iPhone call is the banner itself: caller
/// name, a line such as "FaceTime Video", and Accept/Decline buttons.
struct IncomingCallBanner: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case faceTimeVideo
        case faceTimeAudio
        case phone

        var label: String {
            switch self {
            case .faceTimeVideo: "FaceTime Video"
            case .faceTimeAudio: "FaceTime Audio"
            case .phone: "Call"
            }
        }

        var bundleID: String {
            self == .phone ? "com.apple.mobilephone" : "com.apple.facetime"
        }

        var appName: String { self == .phone ? "Phone" : "FaceTime" }
    }

    let caller: String
    let kind: Kind

    nonisolated static let acceptTitles: Set<String> = ["accept", "answer"]
    nonisolated static let declineTitles: Set<String> = ["decline", "ignore"]

    /// `texts` are the banner's static strings top to bottom, `buttons` the
    /// button titles. Returns nil for anything that is not a ringing call.
    nonisolated static func parse(texts: [String], buttons: [String]) -> IncomingCallBanner? {
        let lowered = Set(buttons.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        guard !lowered.isDisjoint(with: acceptTitles), !lowered.isDisjoint(with: declineTitles) else {
            return nil
        }
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !lowered.contains($0.lowercased()) }
        let joined = cleaned.joined(separator: " ").lowercased()

        let kind: Kind
        if joined.contains("facetime audio") {
            kind = .faceTimeAudio
        } else if joined.contains("facetime") {
            kind = .faceTimeVideo
        } else {
            kind = .phone
        }

        // The caller line is the one that is not describing the call itself.
        let descriptors: Set<String> = ["facetime", "incoming", "iphone", "cellular", "call", "audio", "video", "mobile"]
        let caller = cleaned.first { line in
            let low = line.lowercased()
            if low == "unknown caller" || low == "no caller id" { return true }
            let words = Set(low.split(whereSeparator: { !$0.isLetter }).map(String.init))
            return words.isDisjoint(with: descriptors)
        } ?? cleaned.first ?? "Unknown Caller"
        return IncomingCallBanner(caller: caller, kind: kind)
    }
}

/// A regular macOS banner read from Accessibility, including alerts that
/// never land in the Notification Center store (Electron/Codex, some PWAs).
struct GenericNotificationBanner: Equatable, Sendable {
    let title: String
    let body: String?
    let texts: [String]
    var occurrenceID: String? = nil

    var identity: String {
        [texts.first ?? "", title, body ?? ""].joined(separator: "\u{1F}").lowercased()
    }

    nonisolated static let chrome: Set<String> = [
        "close", "clear", "edit widgets", "notification center", "notifications",
        "options", "show more", "show less", "information", "ok", "cancel",
    ]

    nonisolated static func isNotificationCenterPanel(texts: [String]) -> Bool {
        texts.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Edit Widgets") == .orderedSame
        }
    }

    /// `texts` are the banner's static strings, `buttons` its button titles.
    /// Returns nil for calls and for the Notification Center panel itself.
    nonisolated static func parse(texts: [String], buttons: [String]) -> GenericNotificationBanner? {
        if IncomingCallBanner.parse(texts: texts, buttons: buttons) != nil { return nil }
        if isNotificationCenterPanel(texts: texts + buttons) { return nil }
        // Recent macOS versions combine app, title and body in the group description.
        // The static child repeats title + body, so do not append it a second time.
        for description in texts {
            let stacked = description.hasSuffix(", stacked")
            let label = stacked ? String(description.dropLast(", stacked".count)) : description
            let parts = label.components(separatedBy: ", ")
            if parts.count >= 3 {
                let app = parts[0]
                let title = parts[1]
                let body = parts.dropFirst(2).joined(separator: ", ")
                if stacked || texts.contains("\(title) \(body)") || (texts.contains(title) && texts.contains(body)) {
                    return GenericNotificationBanner(title: title, body: body, texts: [app, title, body])
                }
            }
        }
        let buttonTitles = Set(buttons.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen = Set<String>()
        let unique = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let low = line.lowercased()
                if chrome.contains(low) || buttonTitles.contains(low) { return false }
                if isRelativeTimestamp(low) { return false }
                return seen.insert(low).inserted
            }
        guard let title = unique.first else { return nil }
        let rest = unique.dropFirst()
        let body = rest.isEmpty ? nil : rest.joined(separator: " ")
        return GenericNotificationBanner(title: title, body: body, texts: unique)
    }

    nonisolated static func isRelativeTimestamp(_ line: String) -> Bool {
        if line == "now" { return true }
        if line.hasSuffix(" ago") { return true }
        guard line.count <= 4, let last = line.last, "smhd".contains(last) else { return false }
        return line.dropLast().allSatisfy(\.isNumber)
    }
}

/// Watches Notification Center for incoming-call banners and for regular
/// banners that never reach the store. It never presses Accept or Decline;
/// those stay on the native call banner.
@MainActor
final class IncomingCallWatcher: ObservableObject {
    var onCallBegan: ((IncomingCallBanner) -> Void)?
    var onCallEnded: ((IncomingCallBanner) -> Void)?
    var onGenericBanner: ((GenericNotificationBanner) -> Void)?

    /// For the Settings diagnostics row.
    @Published private(set) var lastSeen: (banner: IncomingCallBanner, at: Date)?
    @Published private(set) var isAttached = false

    private(set) var current: IncomingCallBanner?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var watchPoll: Task<Void, Never>?
    private var attachRetry: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?
    private var started = false
    private var seenGenericIdentities: [String: Date] = [:]

    func start() {
        guard !started else { return }
        started = true
        let bundleID = NativeBannerSuppressor.notificationCenterBundleID
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == bundleID else { return }
            Task { @MainActor in self?.attach() }
        }
        attach()
        startWatchPoll()
    }

    func stop() {
        started = false
        attachRetry?.cancel()
        attachRetry = nil
        watchPoll?.cancel()
        watchPoll = nil
        detach()
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        current = nil
        seenGenericIdentities.removeAll()
    }

    private func attach() {
        guard started, AXIsProcessTrusted() else {
            scheduleAttachRetry()
            return
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: NativeBannerSuppressor.notificationCenterBundleID).first
        else {
            scheduleAttachRetry()
            return
        }
        if observer != nil, observedPID == app.processIdentifier { return }
        detach()

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<IncomingCallWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in watcher.scan() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else {
            scheduleAttachRetry()
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, root, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(created, root, kAXUIElementDestroyedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = app.processIdentifier
        isAttached = true
        notificationLog.info("Incoming call watcher attached to Notification Center \(app.processIdentifier)")
        scan()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
        isAttached = false
        }

    private func scheduleAttachRetry() {
        attachRetry?.cancel()
        attachRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.attach()
        }
    }

    /// Looks for call banners and regular alerts among Notification Center's windows.
    func replayVisibleGenericBanners() {
        seenGenericIdentities.removeAll()
        scan()
    }

    func scan() {
        guard observedPID != 0 else { return }
        let found = Self.findBanners(pid: observedPID)
        switch (current, found.call) {
        case (nil, let banner?):
            current = banner
            lastSeen = (banner, Date())
            notificationLog.info("incoming call: \(banner.kind.label, privacy: .public)")
            onCallBegan?(banner)
        case (let ringing?, nil):
            current = nil
            onCallEnded?(ringing)
        case (let ringing?, let banner?) where ringing != banner:
            current = banner
            lastSeen = (banner, Date())
            onCallEnded?(ringing)
            onCallBegan?(banner)
        default:
            break
        }

        let now = Date()
        seenGenericIdentities = seenGenericIdentities.filter { now.timeIntervalSince($0.value) < 45 }
        for item in found.generic {
            let identity = item.banner.occurrenceID ?? item.banner.identity
            let firstSeen = seenGenericIdentities[identity] == nil
            seenGenericIdentities[identity] = now
            if firstSeen {
                notificationLog.info("ax banner: \(item.banner.title, privacy: .public)")
                onGenericBanner?(item.banner)
            }

        }
    }

    /// Banner creation is not always reported through AX, so the tree is
    /// re-read while the watcher is running.
    private func startWatchPoll() {
        watchPoll?.cancel()
        watchPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    private struct FoundBanners {
        var call: IncomingCallBanner?
        var generic: [(banner: GenericNotificationBanner, element: AXUIElement)] = []
    }

    private static func findBanners(pid: pid_t) -> FoundBanners {
        let root = AXUIElementCreateApplication(pid)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] else {
            return FoundBanners()
        }
        var found = FoundBanners()
        for window in windows {
            var windowTexts: [String] = []
            var windowButtons: [String] = []
            collect(window, depth: 0, texts: &windowTexts, buttons: &windowButtons)
            if GenericNotificationBanner.isNotificationCenterPanel(texts: windowTexts + windowButtons) {
                continue
            }
            let call = IncomingCallBanner.parse(texts: windowTexts, buttons: windowButtons)
            if found.call == nil { found.call = call }
            if call != nil { continue }
            for candidate in NativeBannerSuppressor.bannerCandidates(in: window) {
                let texts = NativeBannerSuppressor.collectTexts(candidate, depth: 0)
                var buttons: [String] = []
                var ignoredTexts: [String] = []
                collect(candidate, depth: 0, texts: &ignoredTexts, buttons: &buttons)
                if IncomingCallBanner.parse(texts: texts, buttons: buttons) != nil { continue }
                if var banner = GenericNotificationBanner.parse(texts: texts, buttons: buttons) {
                    banner.occurrenceID = attribute(candidate, kAXIdentifierAttribute) as? String
                    found.generic.append((banner, candidate))
                }
            }
        }
        return found
    }

    private static func collect(
        _ element: AXUIElement, depth: Int, texts: inout [String], buttons: inout [String]
    ) {
        guard depth <= 8 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let labels = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .compactMap { attribute(element, $0) as? String }
            .filter { !$0.isEmpty }
        if role == kAXButtonRole as String {
            buttons.append(contentsOf: labels)
        } else if role == kAXStaticTextRole as String {
            texts.append(contentsOf: labels)
        }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children {
            collect(child, depth: depth + 1, texts: &texts, buttons: &buttons)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Whether any app is using a camera, which is the practical signal that
/// the screen may be on a call or being shared. There is no public
/// "screen is being shared" API; the camera is the closest honest proxy.
@MainActor
final class CameraUseMonitor: ObservableObject {
    @Published private(set) var cameraInUse = false
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        cameraInUse = Self.anyCameraRunning()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                let running = Self.anyCameraRunning()
                if let self, self.cameraInUse != running { self.cameraInUse = running }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        cameraInUse = false
    }

    nonisolated static func anyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }

        var running = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )
        for device in devices {
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(device, &running, 0, nil, valueSize, &valueSize, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }
}

/// Screen lock state so notifications never light up a locked Mac.
@MainActor
final class ScreenLockMonitor {
    private(set) var isLocked = false
    private(set) var unlockedAt: Date = .distantPast
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isLocked = true }
        })
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isLocked = false
                self?.unlockedAt = Date()
            }
        })
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    /// Alerts that arrived while locked flood in the moment the screen wakes.
    func shouldSuppress(now: Date = Date(), settleAfterUnlock: TimeInterval = 3) -> Bool {
        isLocked || now.timeIntervalSince(unlockedAt) < settleAfterUnlock
    }
}
