import Foundation

struct AgentNotificationContext: Equatable, Sendable {
    var bundleIDs: Set<String>
    var sessionTitle: String?
}

enum NotificationIdentity {
    nonisolated static func normalized(_ text: String) -> String {
        NativeBannerSuppressor.foldForMatch(text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated static func recordID(_ value: String) -> String? {
        guard !value.hasPrefix("ax:words:"), !value.isEmpty else { return nil }
        let value = value.hasPrefix("ax:") ? String(value.dropFirst(3)) : value
        let hex = value.replacingOccurrences(of: "-", with: "").lowercased()
        if hex.count == 32, hex.allSatisfy(\.isHexDigit) { return hex }
        return value.lowercased()
    }

    nonisolated static func words(_ content: SystemNotificationContent) -> String {
        [content.bundleID, content.headline, content.body ?? ""].map(normalized).joined(separator: "\u{1F}")
    }
}

/// Owns arrival ordering, transport redelivery and agent/native correlation.
/// Callers receive one stable key for each native occurrence, even when AX and
/// the notification database report it in opposite orders.
@MainActor
final class NotificationRouter {
    enum Origin: Hashable { case accessibility, store }
    private enum Delivery { case pending, shown, merged, withheld }
    private struct NativeEvent {
        var content: SystemNotificationContent
        var origins: Set<Origin>
        let key: String
        let arrivedAt: Date
        let dueAt: Date
        var delivery: Delivery
    }
    private struct AgentEvent {
        let attention: IslandAgentAttention
        let context: AgentNotificationContext
        let arrivedAt: Date
    }

    var onSystem: ((SystemNotificationContent, String) -> Bool)?
    var onRedelivery: ((SystemNotificationContent) -> Void)?
    var onMerge: ((SystemNotificationContent, String) -> Void)?
    var holdInterval: TimeInterval = 0.35
    private let automaticallyFlush: Bool
    private var native: [NativeEvent] = []
    private var agents: [AgentEvent] = []
    private var flushTask: Task<Void, Never>?

    init(automaticallyFlush: Bool = true) { self.automaticallyFlush = automaticallyFlush }

    func receiveSystem(_ content: SystemNotificationContent, now: Date = Date()) {
        prune(at: now)
        let origin: Origin = content.recordID < 0 ? .accessibility : .store
        if let index = native.firstIndex(where: { sameOccurrence($0, content, origin: origin, now: now) }) {
            native[index].origins.insert(origin)
            if origin == .store || native[index].content.bundleID == "ax.unknown" {
                native[index].content = content
            }
            if matchingAgent(for: native[index].content, at: now) != nil {
                native[index].delivery = .merged
                onMerge?(native[index].content, native[index].key)
            } else if native[index].delivery == .merged {
                onMerge?(native[index].content, native[index].key)
            } else if native[index].delivery == .shown {
                onRedelivery?(native[index].content)
            }
            return
        }
        let key = "system:event:\(UUID().uuidString)"
        let merged = matchingAgent(for: content, at: now) != nil
        native.append(NativeEvent(content: content, origins: [origin], key: key, arrivedAt: now,
                                  dueAt: now.addingTimeInterval(holdInterval), delivery: merged ? .merged : .pending))
        if merged { onMerge?(content, key) }
        flush(at: now)
        scheduleFlush()
    }

    func receiveAgent(_ attention: IslandAgentAttention, context: AgentNotificationContext, now: Date = Date()) {
        prune(at: now)
        agents.removeAll { $0.attention.sessionID == attention.sessionID && $0.attention.kind == attention.kind }
        agents.append(AgentEvent(attention: attention, context: context, arrivedAt: now))
        for index in native.indices where native[index].delivery != .merged {
            guard matchingAgent(for: native[index].content, at: now) != nil else { continue }
            native[index].delivery = .merged
            onMerge?(native[index].content, native[index].key)
        }
        scheduleFlush()
    }

    func flush(at now: Date = Date()) {
        for index in native.indices where native[index].delivery == .pending && native[index].dueAt <= now {
            let accepted = onSystem?(native[index].content, native[index].key) ?? false
            native[index].delivery = accepted ? .shown : .withheld
        }
    }

    func canFinishPresentation(key: String) -> Bool {
        native.contains { $0.key == key && $0.delivery == .shown }
    }

    func withhold(key: String) {
        if let index = native.firstIndex(where: { $0.key == key }) { native[index].delivery = .withheld }
    }

    func key(for content: SystemNotificationContent) -> String? {
        native.first { $0.content.uuid == content.uuid ||
            (NotificationIdentity.recordID(content.uuid) != nil && NotificationIdentity.recordID($0.content.uuid) == NotificationIdentity.recordID(content.uuid))
        }?.key
    }

    func forgetAgents() { agents.removeAll() }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        native.removeAll()
        agents.removeAll()
    }

    private func scheduleFlush() {
        guard automaticallyFlush else { return }
        flushTask?.cancel()
        guard let next = native.filter({ $0.delivery == .pending }).map(\.dueAt).min() else { return }
        let delay = max(0, next.timeIntervalSinceNow)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flush()
            self?.scheduleFlush()
        }
    }

    private func prune(at now: Date) {
        agents.removeAll { now.timeIntervalSince($0.arrivedAt) > 10 }
        native.removeAll { $0.delivery != .pending && now.timeIntervalSince($0.arrivedAt) > 120 }
        if native.count > 512 { native.removeFirst(native.count - 512) }
    }

    private func sameOccurrence(_ old: NativeEvent, _ new: SystemNotificationContent, origin: Origin, now: Date) -> Bool {
        let appMatches = old.content.bundleID.lowercased() == new.bundleID.lowercased()
        let appUnknown = old.content.bundleID == "ax.unknown" || new.bundleID == "ax.unknown"
        guard appMatches || appUnknown else { return false }
        if let oldID = NotificationIdentity.recordID(old.content.uuid), let newID = NotificationIdentity.recordID(new.uuid) {
            return oldID == newID
        }
        guard !old.origins.contains(origin), now.timeIntervalSince(old.arrivedAt) <= 3 else { return false }
        guard appMatches || NotificationIdentity.normalized(old.content.appName) == NotificationIdentity.normalized(new.appName) else { return false }
        return NotificationIdentity.normalized(old.content.headline) == NotificationIdentity.normalized(new.headline)
            && NotificationIdentity.normalized(old.content.body ?? "") == NotificationIdentity.normalized(new.body ?? "")
    }

    private func matchingAgent(for content: SystemNotificationContent, at now: Date) -> AgentEvent? {
        let candidates = agents.filter {
            abs(content.deliveredAt.timeIntervalSince($0.arrivedAt)) <= 10
                && now.timeIntervalSince($0.arrivedAt) <= 10
                && Self.matches(content, attention: $0.attention, context: $0.context)
        }
        guard Set(candidates.compactMap { $0.attention.sessionID }).count == 1 else { return nil }
        return candidates.first
    }

    nonisolated static func matches(_ content: SystemNotificationContent, attention: IslandAgentAttention,
                                   context: AgentNotificationContext) -> Bool {
        guard let sessionID = attention.sessionID, !sessionID.isEmpty,
              context.bundleIDs.contains(content.bundleID.lowercased()) else { return false }
        if let nativeSession = content.agentSessionID, nativeSession != sessionID { return false }
        if let eventID = content.agentEventID { return eventID == attention.requestID }
        let title = NotificationIdentity.normalized(content.headline)
        let titles = [attention.title, context.sessionTitle].compactMap { $0 }.map(NotificationIdentity.normalized)
        guard !title.isEmpty, titles.contains(title) else { return false }
        if attention.kind == .completion { return true }
        guard let detail = attention.detail, !detail.isEmpty, let body = content.body else { return false }
        return NotificationIdentity.normalized(detail) == NotificationIdentity.normalized(body)
    }
}
