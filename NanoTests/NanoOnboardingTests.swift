import AppKit
import SwiftUI
import XCTest
@testable import Nano

@MainActor
final class NanoOnboardingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "NanoOnboardingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testCompletionFlagDefaultsOffAndPersists() {
        let settings = NanoSettings(defaults: defaults)
        XCTAssertFalse(settings.onboardingCompleted)

        settings.completeOnboarding()

        XCTAssertTrue(NanoSettings(defaults: defaults).onboardingCompleted)
    }

    func testFirstRunRequiresExplicitAddOnOptIn() {
        let settings = NanoSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(.agents), "registry default documents why onboarding must intervene")

        settings.prepareForFirstRunOnboardingOnce()

        XCTAssertFalse(settings.isEnabled(.agents))
        XCTAssertFalse(settings.isEnabled(.voiceDictation))
        XCTAssertFalse(settings.isNotificationEnabled(.system))
        XCTAssertFalse(settings.onboardingCompleted)
    }

    func testCompletingSetupDoesNotChangeChosenAddOns() {
        let settings = NanoSettings(defaults: defaults)
        settings.prepareForFirstRunOnboardingOnce()
        settings.setEnabled(true, for: .agents)

        settings.completeOnboarding()

        XCTAssertTrue(settings.isEnabled(.agents))
        XCTAssertFalse(settings.isEnabled(.voiceDictation))
        XCTAssertFalse(settings.isNotificationEnabled(.system))
    }

    func testSupportedAgentsAreTheNineNanoShips() {
        XCTAssertEqual(
            NanoOnboardingPlan.agentProviders,
            [.claude, .codex, .cursor, .devin, .gemini, .grok, .kimi, .opencode, .pi]
        )
    }

    // MARK: - Checklist

    func testChecklistIsEmptyWhenNothingIsOn() {
        XCTAssertTrue(NanoSetupChecklist(.init()).items.isEmpty)
    }

    func testChecklistListsOpenSetupForEnabledFeatures() {
        var facts = NanoSetupChecklist.Facts()
        facts.agentsEnabled = true
        facts.hookableAgentsFound = true
        facts.voiceEnabled = true
        facts.systemNotificationsEnabled = true
        let checklist = NanoSetupChecklist(facts)
        XCTAssertEqual(checklist.items, [
            .connectAgents, .allowMicrophone, .downloadVoiceModel,
            .allowFullDiskAccess, .allowSessionJump, .allowAutoPaste,
        ])
        XCTAssertTrue(checklist.hasRequiredItems)
    }

    func testChecklistWithOnlyOptionalItemsDoesNotNag() {
        var facts = NanoSetupChecklist.Facts()
        facts.agentsEnabled = true
        facts.hookableAgentsFound = true
        facts.hooksInstalled = true
        let checklist = NanoSetupChecklist(facts)
        XCTAssertEqual(checklist.items, [.allowSessionJump])
        XCTAssertFalse(checklist.hasRequiredItems)
    }

    func testChecklistSkipsHooksWhenNoAgentIsInstalled() {
        var facts = NanoSetupChecklist.Facts()
        facts.agentsEnabled = true
        facts.accessibilityTrusted = true
        XCTAssertTrue(NanoSetupChecklist(facts).items.isEmpty)
    }

    func testSkippingSetupKeepsAddOnsOff() {
        let settings = NanoSettings(defaults: defaults)
        settings.prepareForFirstRunOnboardingOnce()

        settings.completeOnboarding()

        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertFalse(settings.isEnabled(.agents))
        XCTAssertFalse(settings.isEnabled(.voiceDictation))
        XCTAssertFalse(settings.isNotificationEnabled(.system))
    }

    func testBatteryAlertOffKeepsAPlacedBatteryWidget() {
        let settings = NanoSettings(defaults: defaults)
        settings.setDashboardFeature(.battery, in: .area3)
        XCTAssertTrue(settings.isEnabled(.battery))

        settings.setNotificationEnabled(false, for: .battery)

        XCTAssertTrue(settings.isEnabled(.battery))
        XCTAssertEqual(settings.dashboardFeature(in: .area3), .battery)
    }

    func testPrereleaseIsNotNewerThanItsRelease() {
        XCTAssertFalse(NanoUpdateChecker.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
        XCTAssertTrue(NanoUpdateChecker.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        XCTAssertTrue(NanoUpdateChecker.isVersion("1.0.0-beta.2", newerThan: "1.0.0-beta.1"))
        XCTAssertTrue(NanoUpdateChecker.isVersion("1.0.1-beta.1", newerThan: "1.0.0"))
    }

    func testFoundUpdateSurvivesARelaunchUntilItIsInstalled() throws {
        let settings = NanoSettings(defaults: defaults)
        let newer = NanoUpdate(
            version: "999.0.0",
            downloadURL: URL(string: "https://example.com/Nano.dmg")!,
            pageURL: URL(string: "https://example.com/release")!,
            notes: nil
        )
        defaults.set(try JSONEncoder().encode(newer), forKey: "updates.pending")
        XCTAssertEqual(NanoUpdateChecker(settings: settings, defaults: defaults).available, newer)

        let installed = NanoUpdate(version: NanoAppInfo.version, downloadURL: newer.downloadURL, pageURL: newer.pageURL, notes: nil)
        defaults.set(try JSONEncoder().encode(installed), forKey: "updates.pending")
        XCTAssertNil(NanoUpdateChecker(settings: settings, defaults: defaults).available)
        XCTAssertNil(defaults.data(forKey: "updates.pending"))
    }

    func testUpdateSummarySkipsHeadingsAndListMarkers() {
        XCTAssertEqual(NanoUpdate.preview.summary, "Faster tray and a quieter Mixer")
    }
}

@MainActor
final class OnboardingPickTests: XCTestCase {
    private func makeFlow(_ settings: NanoSettings, replay: Bool = false) -> OnboardingFlow {
        let viewModel = IslandViewModel(settings: settings, trayStorageURL: nil)
        return OnboardingFlow(settings: settings, viewModel: viewModel, isReplay: replay, onComplete: {})
    }

    private func freshSettings() -> NanoSettings {
        NanoSettings(defaults: UserDefaults(suiteName: "nano-pick-\(UUID().uuidString)")!)
    }

    func testFirstRunStartsWithNothingPicked() {
        let settings = freshSettings()
        settings.prepareForFirstRunOnboardingOnce()
        let flow = makeFlow(settings)
        XCTAssertTrue(flow.picks.isEmpty)
        flow.tearDown()
    }

    func testReplayPicksStartFromWhatIsOn() {
        let settings = freshSettings()
        settings.completeOnboarding()
        let flow = makeFlow(settings, replay: true)
        for feature in OnboardingFeature.offered {
            guard let module = feature.module else { continue }
            XCTAssertEqual(flow.isPicked(feature), settings.isEnabled(module), "\(feature)")
        }
        flow.tearDown()
    }

    func testFirstRunResetRunsOnce() {
        let settings = freshSettings()
        settings.prepareForFirstRunOnboardingOnce()
        settings.setEnabled(true, for: .agents)
        settings.prepareForFirstRunOnboardingOnce()
        XCTAssertTrue(settings.isEnabled(.agents), "a relaunch midway keeps what setup turned on")
    }

    func testSetUpLaterMarksSetupDone() {
        let settings = freshSettings()
        settings.prepareForFirstRunOnboardingOnce()
        let flow = makeFlow(settings)
        flow.setUpLater()
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertNil(settings.onboardingProgress)
        flow.tearDown()
    }

    func testRoomsFollowTheDesignOrder() {
        let settings = freshSettings()
        let flow = makeFlow(settings)
        flow.openWindow()
        for feature in OnboardingFeature.offered { flow.toggle(feature) }
        XCTAssertEqual(flow.rooms, [.notifications, .agents, .voice, .sketch, .cue, .mixer, .dashboard])
        flow.tearDown()
    }

    func testProgressIsSavedAndOfferedOnTheNextLaunch() {
        let settings = freshSettings()
        settings.prepareForFirstRunOnboardingOnce()
        let flow = makeFlow(settings)
        flow.openWindow()
        XCTAssertEqual(flow.step, .welcome)
        flow.next()
        XCTAssertEqual(flow.step, .pick)
        flow.toggle(.cue)
        flow.startRooms()
        XCTAssertEqual(flow.currentRoom, .cue)
        XCTAssertTrue(settings.isEnabled(.cue))
        XCTAssertEqual(settings.onboardingProgress?.step, .room(.cue))
        XCTAssertEqual(settings.onboardingProgress?.picks, ["cue"])
        flow.tearDown()

        let next = makeFlow(settings)
        next.start()
        XCTAssertEqual(next.step, .resume)
        XCTAssertEqual(next.resumeTitle, "Cue")
        next.continueSetup()
        XCTAssertEqual(next.currentRoom, .cue)
        next.tearDown()
    }

    func testJustTheIslandTurnsEveryFeatureOff() {
        let settings = freshSettings()
        settings.prepareForFirstRunOnboardingOnce()
        let flow = makeFlow(settings)
        flow.openWindow()
        flow.next()
        flow.justTheIsland()
        XCTAssertEqual(flow.step, .summary)
        for feature in OnboardingFeature.allCases {
            guard let module = feature.module else { continue }
            XCTAssertFalse(settings.isEnabled(module), "\(feature)")
        }
        flow.tearDown()
    }
}
