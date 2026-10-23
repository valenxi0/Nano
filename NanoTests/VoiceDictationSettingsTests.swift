import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Nano

@MainActor
final class VoiceDictationSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "nano-vd-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testDefaultsFollowTheHandoff() {
        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(settings.voiceDictationEngine, .parakeetS1, "Parakeet + S1-mini is the preferred engine")
        XCTAssertEqual(settings.voiceDictationActivationMode, .pushToTalk)
        XCTAssertFalse(settings.voiceDictationHistoryEnabled, "history is opt-in")
        XCTAssertEqual(settings.voiceDictationHotkey, .default)
        XCTAssertTrue(settings.voiceDictationVocabulary.isEmpty)
        XCTAssertFalse(settings.isEnabled(.voiceDictation), "the feature is opt-in")
    }

    func testValuesRoundTripThroughUserDefaults() {
        let entry = VoiceDictationVocabularyEntry(phrase: "north star", replacement: "Nano", kind: .vocabulary)
        let snippet = VoiceDictationVocabularyEntry(phrase: "sign off", replacement: "Best,\nJ", kind: .snippet, isEnabled: false)
        let hotkey = VoiceDictationHotkey(keyCode: 49, modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue)

        do {
            let settings = NanoSettings(defaults: defaults)
            settings.voiceDictationEngine = .whisperBase
            settings.voiceDictationActivationMode = .toggle
            settings.voiceDictationHistoryEnabled = true
            settings.voiceDictationHotkey = hotkey
            settings.voiceDictationVocabulary = [entry, snippet]
            settings.setEnabled(true, for: .voiceDictation)
        }

        let reloaded = NanoSettings(defaults: defaults)
        XCTAssertEqual(reloaded.voiceDictationEngine, .whisperBase)
        XCTAssertEqual(reloaded.voiceDictationActivationMode, .toggle)
        XCTAssertTrue(reloaded.voiceDictationHistoryEnabled)
        XCTAssertEqual(reloaded.voiceDictationHotkey, hotkey)
        XCTAssertEqual(reloaded.voiceDictationVocabulary, [entry, snippet])
        XCTAssertTrue(reloaded.isEnabled(.voiceDictation))
    }

    func testCorruptStoredValuesFallBackToDefaults() {
        defaults.set("not-an-engine", forKey: "voiceDictation.engine")
        defaults.set("garbage", forKey: "voiceDictation.hotkey")
        defaults.set(Data("{".utf8), forKey: "voiceDictation.vocabulary")
        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(settings.voiceDictationEngine, .parakeetS1)
        XCTAssertEqual(settings.voiceDictationHotkey, .default)
        XCTAssertTrue(settings.voiceDictationVocabulary.isEmpty)
    }

    // MARK: Hotkey codec

    func testHotkeyStorageValueRoundTrips() {
        let hotkey = VoiceDictationHotkey(keyCode: 46, modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue)
        XCTAssertEqual(VoiceDictationHotkey(storageValue: hotkey.storageValue), hotkey)
        XCTAssertNil(VoiceDictationHotkey(storageValue: "46"))
        XCTAssertNil(VoiceDictationHotkey(storageValue: "a:b"))
        XCTAssertNil(VoiceDictationHotkey(storageValue: ""))
    }

    func testHotkeyMasksDeviceDependentBits() {
        let raw = NSEvent.ModifierFlags.command.rawValue | 0x1 // 0x1 is a device-dependent bit
        let hotkey = VoiceDictationHotkey(keyCode: 0, modifierFlags: raw)
        XCTAssertEqual(hotkey.modifierFlags, NSEvent.ModifierFlags.command.rawValue)
    }

    func testHotkeyNeedsAModifierAndDescribesItself() {
        XCTAssertFalse(VoiceDictationHotkey(keyCode: 46, modifierFlags: 0).isUsable)
        XCTAssertTrue(VoiceDictationHotkey.default.isUsable)
        XCTAssertEqual(VoiceDictationHotkey.default.displayString, "⌃⌥M")
        let space = VoiceDictationHotkey(keyCode: 49, modifierFlags: NSEvent.ModifierFlags([.shift, .command]).rawValue)
        XCTAssertEqual(space.displayString, "⇧⌘Space")
    }

    func testCarbonModifierTranslation() {
        let flags = NSEvent.ModifierFlags([.command, .control, .option, .shift])
        let carbon = VoiceDictationHotkeyMonitor.carbonModifiers(for: flags)
        XCTAssertEqual(carbon, UInt32(cmdKey | controlKey | optionKey | shiftKey))
        XCTAssertEqual(VoiceDictationHotkeyMonitor.carbonModifiers(for: []), 0)
    }

    // MARK: Registry

    func testModuleIsRegistered() {
        let descriptor = NanoModuleRegistry.descriptor(for: .voiceDictation)
        XCTAssertEqual(descriptor.title, "Quill")
        XCTAssertFalse(descriptor.isEnabledByDefault)
        XCTAssertTrue(descriptor.dashboardAreas.isEmpty, "not a dashboard widget")
        XCTAssertTrue(NanoModuleRegistry.modules.contains(descriptor), "listed in General → Features")
    }

    func testSettingsSidebarHidesVoiceWhenDisabled() {
        let settings = NanoSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled(.voiceDictation))
        XCTAssertFalse(SettingsDestination.available(settings: settings).contains(.voiceDictation))

        settings.setEnabled(true, for: .voiceDictation)
        XCTAssertTrue(SettingsDestination.available(settings: settings).contains(.voiceDictation))
    }

    func testInsightsAreOnByDefault() {
        XCTAssertTrue(NanoSettings(defaults: defaults).voiceDictationInsightsEnabled)
    }

    func testStatsStoreKeepsCountsAndNeverText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nano-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = VoiceDictationStatsStore(fileURL: url, calendar: calendar)
        let entry = UUID()
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        store.record(words: 120, seconds: 60, fillersRemoved: 3, dictionaryEntryIDs: [entry], latency: 0.4,
                     app: ("com.apple.MobileSMS", "Messages"), at: yesterday)
        store.record(words: 80, seconds: 30, fillersRemoved: 1, dictionaryEntryIDs: [entry], latency: 0.6,
                     app: ("com.apple.MobileSMS", "Messages"), at: today)
        store.record(words: 0, seconds: 10, fillersRemoved: 0, dictionaryEntryIDs: [], latency: nil, app: nil, at: today)

        XCTAssertEqual(store.totalWords, 200)
        XCTAssertEqual(store.currentStreak, 2)
        XCTAssertEqual(store.longestStreak, 2)
        XCTAssertEqual(store.stats.fillersRemoved, 4)
        XCTAssertEqual(store.hits(for: entry), 2)
        XCTAssertEqual(try XCTUnwrap(store.speed(now: today)), 200 / 1.5, accuracy: 0.01)
        // 200 words at 40 wpm is 300 s of typing, less 90 s spoken.
        XCTAssertEqual(store.timeSaved(from: yesterday, through: today), 210, accuracy: 0.01)

        let reloaded = VoiceDictationStatsStore(fileURL: url, calendar: calendar)
        // Dates round-trip at ISO 8601 second precision; the counts must match exactly.
        XCTAssertEqual(reloaded.stats.days, store.stats.days)
        XCTAssertEqual(reloaded.stats.appWords, store.stats.appWords)
        XCTAssertEqual(reloaded.stats.dictionaryHits, store.stats.dictionaryHits)
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains("dinner"), "stats hold no transcript text")

        store.reset()
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFillerCountingComparesRawAndFinal() {
        XCTAssertEqual(VoiceDictationStatsStore.fillerCount("Um, so uh I think, erm, yes"), 3)
        XCTAssertEqual(VoiceDictationStatsStore.fillersRemoved(raw: "um dinner uh at eight", final: "Dinner at eight."), 2)
        XCTAssertEqual(VoiceDictationStatsStore.fillersRemoved(raw: "dinner", final: "um dinner"), 0)
    }
}
