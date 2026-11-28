import XCTest
@testable import Nano

@MainActor
private final class RecordingPlayer: AgentSoundPlaying {
    var played: [AgentAlertSound] = []
    func play(_ sound: AgentAlertSound) { played.append(sound) }
}

private struct FixedProbe: AgentQuietProbing {
    var value = AgentQuietConditions()
    func conditions() -> AgentQuietConditions { value }
}

/// Agent alerts: what is stored, when it is quiet, and that each request
/// sounds once and is reminded at most three times while still pending.
@MainActor
final class AgentAlertsTests: XCTestCase {
    private func attention(_ id: String, kind: AgentHookBridge.RequestKind) -> IslandAgentAttention {
        IslandAgentAttention(AgentHookBridge.PendingRequest(
            id: id,
            source: "claude",
            kind: kind,
            title: "Bash",
            detail: nil,
            options: [],
            sessionID: "s",
            receivedAt: Date(),
            projectName: "p"
        ))
    }

    private func noon() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func center(
        preferences: AgentAlertPreferences = AgentAlertPreferences(),
        probe: FixedProbe = FixedProbe(),
        pending: @escaping (String) -> Bool = { _ in false },
        player: RecordingPlayer,
        represented: @escaping (IslandAgentAttention) -> Void = { _ in }
    ) -> AgentAlertCenter {
        let date = noon()
        return AgentAlertCenter(
            preferences: { preferences },
            isPending: pending,
            represent: represented,
            player: player,
            probe: probe,
            now: { date },
            sleep: { _ in }
        )
    }

    // MARK: Stored values

    func testSoundsSurviveStorage() {
        for sound in [AgentAlertSound.none, .system("Glass"), .file("/Users/me/ding.wav")] {
            XCTAssertEqual(AgentAlertSound(storageValue: sound.storageValue), sound)
        }
        XCTAssertNil(AgentAlertSound(storageValue: "system:NotASound"))
        XCTAssertNil(AgentAlertSound(storageValue: "file:relative.wav"))
        XCTAssertNil(AgentAlertSound(storageValue: "garbage"))
    }

    func testPreferencesRoundTrip() throws {
        var preferences = AgentAlertPreferences()
        preferences.setSound(.file("/tmp/a.wav"), for: .approval)
        preferences.setSound(.none, for: .completion)
        preferences.quietSchedule = AgentQuietSchedule(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        preferences.remindersEnabled = true
        preferences.reminderMinutes = 5
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(AgentAlertPreferences.self, from: data), preferences)
    }

    func testEmptyOrPartialSettingsFallBackPerField() throws {
        let empty = try JSONDecoder().decode(AgentAlertPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AgentAlertPreferences())
        XCTAssertTrue(empty.soundsEnabled, "sounds are on by default")

        let partial = try JSONDecoder().decode(AgentAlertPreferences.self, from: Data("""
        {"sounds": {"approval": "system:Hero", "question": "system:Removed"}, "reminderMinutes": 7}
        """.utf8))
        XCTAssertEqual(partial.sound(for: .approval), .system("Hero"))
        XCTAssertEqual(partial.sound(for: .question), .system("Ping"), "an unreadable sound falls back to the default")
        XCTAssertEqual(partial.reminderMinutes, 2, "a reminder interval Nano doesn't offer falls back")
    }

    func testChoosingTheDefaultStoresNothing() {
        var preferences = AgentAlertPreferences()
        preferences.setSound(.system("Hero"), for: .approval)
        XCTAssertFalse(preferences.sounds.isEmpty)
        preferences.setSound(.system("Glass"), for: .approval)
        XCTAssertTrue(preferences.sounds.isEmpty)
    }

    func testEveryRequestKindHasAnEvent() {
        XCTAssertEqual(AgentAlertEvent(kind: .permission), .approval)
        XCTAssertEqual(AgentAlertEvent(kind: .question), .question)
        XCTAssertEqual(AgentAlertEvent(kind: .notification), .question)
        XCTAssertEqual(AgentAlertEvent(kind: .completion), .completion)
    }

    // MARK: Quiet

    func testQuietHoursWithinADay() {
        let schedule = AgentQuietSchedule(isEnabled: true, startMinute: 13 * 60, endMinute: 14 * 60)
        XCTAssertFalse(schedule.contains(minute: 12 * 60 + 59))
        XCTAssertTrue(schedule.contains(minute: 13 * 60))
        XCTAssertTrue(schedule.contains(minute: 13 * 60 + 59))
        XCTAssertFalse(schedule.contains(minute: 14 * 60))
    }

    func testQuietHoursPastMidnight() {
        let schedule = AgentQuietSchedule(isEnabled: true, startMinute: 23 * 60, endMinute: 8 * 60)
        XCTAssertTrue(schedule.contains(minute: 23 * 60 + 30))
        XCTAssertTrue(schedule.contains(minute: 0))
        XCTAssertTrue(schedule.contains(minute: 7 * 60 + 59))
        XCTAssertFalse(schedule.contains(minute: 8 * 60))
        XCTAssertFalse(schedule.contains(minute: 12 * 60))
    }

    func testDisabledOrEmptyScheduleIsNeverQuiet() {
        XCTAssertFalse(AgentQuietSchedule(isEnabled: false, startMinute: 0, endMinute: 1439).contains(minute: 600))
        XCTAssertFalse(AgentQuietSchedule(isEnabled: true, startMinute: 600, endMinute: 600).contains(minute: 600))
    }

    func testConditionsOnlyCountWhenTheirToggleIsOn() {
        var preferences = AgentAlertPreferences()
        let locked = AgentQuietConditions(screenLocked: true, microphoneInUse: false)
        let inCall = AgentQuietConditions(screenLocked: false, microphoneInUse: true)
        XCTAssertTrue(preferences.isQuiet(minuteOfDay: 720, conditions: locked))
        XCTAssertTrue(preferences.isQuiet(minuteOfDay: 720, conditions: inCall))
        preferences.quietWhenScreenLocked = false
        preferences.quietWhenMicrophoneInUse = false
        XCTAssertFalse(preferences.isQuiet(minuteOfDay: 720, conditions: locked))
        XCTAssertFalse(preferences.isQuiet(minuteOfDay: 720, conditions: inCall))
    }

    // MARK: Alert center

    func testEachRequestSoundsOnceWithItsEventsSound() {
        let player = RecordingPlayer()
        let alerts = center(player: player)
        alerts.didPresent(attention("a", kind: .permission))
        alerts.didPresent(attention("a", kind: .permission))
        alerts.didPresent(attention("b", kind: .completion))
        XCTAssertEqual(player.played, [.system("Glass"), .system("Pop")])
    }

    func testSoundsOffOrQuietPlaysNothing() {
        var off = AgentAlertPreferences()
        off.soundsEnabled = false
        let silentPlayer = RecordingPlayer()
        center(preferences: off, player: silentPlayer).didPresent(attention("a", kind: .question))
        XCTAssertTrue(silentPlayer.played.isEmpty)

        let quietPlayer = RecordingPlayer()
        let inCall = FixedProbe(value: AgentQuietConditions(screenLocked: false, microphoneInUse: true))
        center(probe: inCall, player: quietPlayer).didPresent(attention("a", kind: .question))
        XCTAssertTrue(quietPlayer.played.isEmpty)
    }

    func testPreviewPlaysEvenWhenQuiet() {
        let player = RecordingPlayer()
        let locked = FixedProbe(value: AgentQuietConditions(screenLocked: true, microphoneInUse: false))
        center(probe: locked, player: player).preview(.system("Tink"))
        XCTAssertEqual(player.played, [.system("Tink")])
    }

    func testPendingRequestIsRemindedThreeTimes() async {
        var preferences = AgentAlertPreferences()
        preferences.remindersEnabled = true
        let player = RecordingPlayer()
        var represented = 0
        let alerts = center(preferences: preferences, pending: { _ in true }, player: player) { _ in represented += 1 }
        alerts.didPresent(attention("a", kind: .permission))
        for _ in 0..<50 where represented < AgentAlertPreferences.maximumReminders {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(represented, 3)
        XCTAssertEqual(player.played.count, 4, "the first sound plus one per reminder")
    }

    func testAnsweredRequestsAndFinishedTurnsAreNotReminded() async {
        var preferences = AgentAlertPreferences()
        preferences.remindersEnabled = true
        let player = RecordingPlayer()
        var represented = 0
        let alerts = center(preferences: preferences, pending: { _ in false }, player: player) { _ in represented += 1 }
        alerts.didPresent(attention("answered", kind: .permission))
        alerts.didPresent(attention("done", kind: .completion))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(represented, 0)
        XCTAssertEqual(player.played.count, 2)
    }

    func testRemindersOffMeansNoReminders() async {
        let player = RecordingPlayer()
        var represented = 0
        let alerts = center(pending: { _ in true }, player: player) { _ in represented += 1 }
        alerts.didPresent(attention("a", kind: .question))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(represented, 0)
    }
}

/// Usage alerts: one per window per reset period, a reset notice after it,
/// and no repeat after a restart.
@MainActor
final class AgentUsageAlertTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 2_000_000_000)

    private func window(_ used: Double, resetsIn hours: Double? = 2, id: String = "claude.5h", at offset: TimeInterval = 0) -> NanoUsageWindow {
        NanoUsageWindow(
            id: id,
            label: "5h",
            usedPercent: used,
            resetsAt: hours.map { base.addingTimeInterval($0 * 3600 + offset) },
            resetAfterSeconds: nil
        )
    }

    func testCrossingTheThresholdAlertsOncePerPeriod() {
        var tracker = AgentUsageAlertTracker()
        XCTAssertTrue(tracker.evaluate([(.claude, window(60))], threshold: 80).isEmpty)
        XCTAssertEqual(tracker.evaluate([(.claude, window(82))], threshold: 80).map(\.kind), [.threshold])
        XCTAssertTrue(tracker.evaluate([(.claude, window(90))], threshold: 80).isEmpty, "same period, already said")
        XCTAssertTrue(tracker.evaluate([(.claude, window(95, at: 40))], threshold: 80).isEmpty,
                      "a reset time that drifts by seconds is the same period")
    }

    func testANewPeriodAnnouncesTheResetThenCanAlertAgain() {
        var tracker = AgentUsageAlertTracker()
        _ = tracker.evaluate([(.claude, window(85, resetsIn: 1))], threshold: 80)
        XCTAssertEqual(tracker.evaluate([(.claude, window(3, resetsIn: 6))], threshold: 80).map(\.kind), [.reset])
        XCTAssertEqual(tracker.evaluate([(.claude, window(81, resetsIn: 6))], threshold: 80).map(\.kind), [.threshold])
    }

    func testANewPeriodAlreadyPastTheLineAlertsAgain() {
        var tracker = AgentUsageAlertTracker()
        _ = tracker.evaluate([(.claude, window(85, resetsIn: 1))], threshold: 80)
        XCTAssertEqual(tracker.evaluate([(.claude, window(88, resetsIn: 6))], threshold: 80).map(\.kind), [.threshold])
    }

    func testAWindowWithoutResetTimeRearmsWellUnderTheLine() {
        var tracker = AgentUsageAlertTracker()
        _ = tracker.evaluate([(.cursor, window(85, resetsIn: nil))], threshold: 80)
        XCTAssertTrue(tracker.evaluate([(.cursor, window(78, resetsIn: nil))], threshold: 80).isEmpty, "a small dip is not a reset")
        XCTAssertEqual(tracker.evaluate([(.cursor, window(60, resetsIn: nil))], threshold: 80).map(\.kind), [.reset])
        XCTAssertEqual(tracker.evaluate([(.cursor, window(85, resetsIn: nil))], threshold: 80).map(\.kind), [.threshold])
    }

    func testWindowsAreTrackedSeparately() {
        var tracker = AgentUsageAlertTracker()
        let alerts = tracker.evaluate([
            (.claude, window(85, id: "claude.5h")),
            (.claude, window(40, id: "claude.7d")),
            (.codex, window(90, id: "codex.primary")),
        ], threshold: 80)
        XCTAssertEqual(alerts.map(\.key), ["claude|claude.5h", "codex|codex.primary"])
    }

    private func snapshot(_ provider: AgentProviderID, _ windows: [NanoUsageWindow], hasQuota: Bool = true) -> AgentProviderSnapshot {
        var snapshot = AgentProviderSnapshot(
            id: provider, isConfigured: true, isActive: false, projectName: nil,
            lastActivityAt: nil, usage: windows, usageMessage: nil
        )
        snapshot.hasQuota = hasQuota
        return snapshot
    }

    func testTheCenterPresentsPlaysAndRemembersAcrossLaunches() throws {
        let suite = "NanoTests.usageAlerts.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        func makeCenter(player: RecordingPlayer, presented: @escaping (AgentUsageAlert) -> Void) -> AgentAlertCenter {
            AgentAlertCenter(
                preferences: { AgentAlertPreferences() },
                isPending: { _ in false },
                represent: { _ in },
                player: player,
                probe: FixedProbe(),
                now: { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! },
                sleep: { _ in },
                presentUsage: presented,
                usageStore: store
            )
        }
        let player = RecordingPlayer()
        var presented: [AgentUsageAlert] = []
        makeCenter(player: player) { presented.append($0) }
            .usageDidRefresh([snapshot(.claude, [window(85)]), snapshot(.openrouter, [window(99, id: "or")], hasQuota: false)])
        XCTAssertEqual(presented.map(\.key), ["claude|claude.5h"], "providers without a quota are skipped")
        XCTAssertEqual(player.played, [.system("Hero")])

        // Nano restarts: the same window in the same period stays quiet.
        let relaunched = RecordingPlayer()
        var again: [AgentUsageAlert] = []
        makeCenter(player: relaunched) { again.append($0) }.usageDidRefresh([snapshot(.claude, [window(87)])])
        XCTAssertTrue(again.isEmpty)
        XCTAssertTrue(relaunched.played.isEmpty)
    }

    func testUsageAlertsOffOrResetAlertsOff() {
        var off = AgentAlertPreferences()
        off.usageAlertsEnabled = false
        var presented = 0
        AgentAlertCenter(preferences: { off }, isPending: { _ in false }, represent: { _ in },
                         player: RecordingPlayer(), probe: FixedProbe(), presentUsage: { _ in presented += 1 }, usageStore: nil)
            .usageDidRefresh([snapshot(.claude, [window(95)])])
        XCTAssertEqual(presented, 0)

        var noResets = AgentAlertPreferences()
        noResets.usageResetAlerts = false
        var kinds: [AgentUsageAlert.Kind] = []
        let center = AgentAlertCenter(preferences: { noResets }, isPending: { _ in false }, represent: { _ in },
                                      player: RecordingPlayer(), probe: FixedProbe(), presentUsage: { kinds.append($0.kind) }, usageStore: nil)
        center.usageDidRefresh([snapshot(.claude, [window(95, resetsIn: 1)])])
        center.usageDidRefresh([snapshot(.claude, [window(2, resetsIn: 6)])])
        XCTAssertEqual(kinds, [.threshold])
    }

    func testOlderSettingsGetUsageDefaults() throws {
        let decoded = try JSONDecoder().decode(AgentAlertPreferences.self, from: Data(#"{"soundsEnabled": false}"#.utf8))
        XCTAssertTrue(decoded.usageAlertsEnabled)
        XCTAssertEqual(decoded.usageThreshold, 80)
        XCTAssertTrue(decoded.usageResetAlerts)
        let odd = try JSONDecoder().decode(AgentAlertPreferences.self, from: Data(#"{"usageThreshold": 33}"#.utf8))
        XCTAssertEqual(odd.usageThreshold, 80)
    }
}
