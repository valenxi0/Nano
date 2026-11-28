import AppKit
import Foundation

/// ⌃⌥1 to ⌃⌥9 answer the question card on screen with that option.
///
/// The chords are claimed only while an answerable question card is showing
/// and released as soon as it goes, so other apps keep them the rest of the
/// time. Control-Option is the family Nano's other shortcuts use; Command-
/// number would take tab switching away from terminals and browsers.
@MainActor
final class AgentOptionHotkeys {
    static let maximum = 9
    /// kVK_ANSI_1 … kVK_ANSI_9.
    static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func hotkey(forOption index: Int) -> VoiceDictationHotkey {
        VoiceDictationHotkey(
            keyCode: digitKeyCodes[index],
            modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue
        )
    }

    static func label(forOption index: Int) -> String {
        "\u{2303}\u{2325}\(index + 1)"
    }

    /// The question that gets keys: the card on screen, when it can be
    /// answered from the island.
    static func target(of notification: IslandNotification?) -> IslandAgentAttention? {
        guard case let .agent(attention)? = notification?.payload,
              attention.kind == .question,
              attention.respondsThroughBridge,
              !attention.options.isEmpty
        else { return nil }
        return attention
    }

    /// Called with the request and the option's position when a chord fires.
    var onChoose: ((_ requestID: String, _ index: Int) -> Void)?

    private(set) var requestID: String?
    /// Options whose chord was registered. Another app holding one leaves
    /// that option without a key rather than failing the rest.
    private(set) var activeIndices: Set<Int> = []

    private let slots: [QuickCaptureHotkey]

    init(idBase: UInt32 = 100) {
        slots = (0..<Self.maximum).map { QuickCaptureHotkey(id: idBase + UInt32($0)) }
        for (index, slot) in slots.enumerated() {
            slot.onPress = { [weak self] in
                guard let self, let requestID, activeIndices.contains(index) else { return }
                // One answer per question: a second chord finds nothing held.
                release()
                onChoose?(requestID, index)
            }
        }
    }

    /// Holds the chords for this question, or releases them when nil.
    func sync(with attention: IslandAgentAttention?) {
        guard attention?.requestID != requestID else { return }
        release()
        guard let attention else { return }
        requestID = attention.requestID
        for index in 0..<min(attention.options.count, Self.maximum)
        where slots[index].register(Self.hotkey(forOption: index)) {
            activeIndices.insert(index)
        }
    }

    func release() {
        slots.forEach { $0.unregister() }
        activeIndices = []
        requestID = nil
    }
}
