import Carbon.HIToolbox
import XCTest
@testable import Nano

/// ⌃⌥1–9 answer the question card on screen. The chords must be the real
/// number keys, held only for an answerable question.
@MainActor
final class AgentOptionHotkeysTests: XCTestCase {
    private func card(_ kind: AgentHookBridge.RequestKind, options: Int, bridge: Bool = true) -> IslandNotification {
        .agent(IslandAgentAttention(AgentHookBridge.PendingRequest(
            id: "req-\(kind.rawValue)-\(options)",
            source: "claude",
            kind: kind,
            title: "Which one?",
            detail: nil,
            options: (0..<options).map { .init(id: $0, label: "Option \($0 + 1)") },
            sessionID: "s",
            receivedAt: Date(),
            respondsThroughBridge: bridge,
            projectName: "p"
        )))
    }

    func testChordsAreControlOptionAndTheRealNumberKeys() {
        let carbon = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(UInt16.init)
        XCTAssertEqual(AgentOptionHotkeys.digitKeyCodes, carbon)
        let first = AgentOptionHotkeys.hotkey(forOption: 0)
        XCTAssertEqual(first.modifiers.intersection([.control, .option, .command, .shift]), [.control, .option])
        XCTAssertTrue(first.isUsable)
        XCTAssertEqual(AgentOptionHotkeys.label(forOption: 2), "⌃⌥3")
    }

    func testOnlyAnAnswerableQuestionGetsKeys() {
        XCTAssertNotNil(AgentOptionHotkeys.target(of: card(.question, options: 3)))
        XCTAssertNil(AgentOptionHotkeys.target(of: card(.question, options: 0)), "nothing to choose")
        XCTAssertNil(AgentOptionHotkeys.target(of: card(.question, options: 3, bridge: false)), "answered in the agent's own window")
        XCTAssertNil(AgentOptionHotkeys.target(of: card(.permission, options: 2)), "approvals keep their own keys")
        XCTAssertNil(AgentOptionHotkeys.target(of: nil))
    }

    func testChordsFollowTheCardOnScreenAndAreReleased() {
        let hotkeys = AgentOptionHotkeys(idBase: 900)
        defer { hotkeys.release() }
        let question = AgentOptionHotkeys.target(of: card(.question, options: 12))
        hotkeys.sync(with: question)
        XCTAssertEqual(hotkeys.requestID, question?.requestID)
        XCTAssertTrue(hotkeys.activeIndices.isSubset(of: Set(0..<AgentOptionHotkeys.maximum)), "never past ⌃⌥9")
        hotkeys.sync(with: nil)
        XCTAssertNil(hotkeys.requestID)
        XCTAssertTrue(hotkeys.activeIndices.isEmpty)
    }
}
