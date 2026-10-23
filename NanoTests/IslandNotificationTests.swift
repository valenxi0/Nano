import AppKit
import SceneKit
import SwiftUI
import XCTest
@testable import Nano

@MainActor
final class NotificationRouterTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
    private let context = AgentNotificationContext(bundleIDs: ["example.agent"], sessionTitle: "Build widgets")

    private func content(_ id: String = "one", app: String = "example.agent", record: Int64 = 1,
                         body: String = "Finished") -> SystemNotificationContent {
        SystemNotificationContent(recordID: record, uuid: id, bundleID: app, appName: "Example",
                                  title: "Build widgets", subtitle: nil, body: body, deliveredAt: now)
    }

    private func attention(session: String = "session", kind: AgentHookBridge.RequestKind = .completion) -> IslandAgentAttention {
        IslandAgentAttention(.init(id: "event-\(session)", source: "future-provider", kind: kind,
            title: "Build widgets", detail: "Approve this change?", options: [], sessionID: session, receivedAt: now))
    }

    func testBothArrivalOrdersKeepOnlyAgentCard() {
        for nativeFirst in [true, false] {
            let router = NotificationRouter(automaticallyFlush: false)
            var shown = 0
            var merged = 0
            router.onSystem = { _, _ in shown += 1; return true }
            router.onMerge = { _, _ in merged += 1 }
            if nativeFirst { router.receiveSystem(content(), now: now) }
            router.receiveAgent(attention(), context: context, now: now.addingTimeInterval(0.1))
            if !nativeFirst { router.receiveSystem(content(), now: now.addingTimeInterval(0.2)) }
            router.flush(at: now.addingTimeInterval(1))
            XCTAssertEqual(shown, 0)
            XCTAssertEqual(merged, 1)
        }
    }

    func testLateHookRemovesAlreadyShownGenericCardUsingSameKey() {
        let router = NotificationRouter(automaticallyFlush: false)
        var shownKey: String?
        var removedKey: String?
        router.onSystem = { _, key in shownKey = key; return true }
        router.onMerge = { _, key in removedKey = key }
        router.receiveSystem(content(), now: now)
        router.flush(at: now.addingTimeInterval(1))
        router.receiveAgent(attention(), context: context, now: now.addingTimeInterval(2))
        XCTAssertNotNil(shownKey)
        XCTAssertEqual(shownKey, removedKey)
    }

    func testTransportUUIDFormattingMergesButDistinctRepeatedMessagesSurvive() {
        let router = NotificationRouter(automaticallyFlush: false)
        var shown: [String] = []
        router.onSystem = { content, _ in shown.append(content.uuid); return true }
        router.receiveSystem(content("ax:12345678-1234-1234-1234-123456789ABC", record: -1), now: now)
        router.receiveSystem(content("12345678123412341234123456789abc"), now: now)
        router.receiveSystem(content("another-unique-event"), now: now)
        router.flush(at: now.addingTimeInterval(1))
        XCTAssertEqual(shown.count, 2)
    }

    func testUnknownIdentityIsEnrichedBeforeAgentMatching() {
        let router = NotificationRouter(automaticallyFlush: false)
        var shown = 0
        var merged = 0
        router.onSystem = { _, _ in shown += 1; return true }
        router.onMerge = { _, _ in merged += 1 }
        router.receiveAgent(attention(), context: context, now: now)
        router.receiveSystem(content("ax:one", app: "ax.unknown", record: -1), now: now)
        router.receiveSystem(content("one"), now: now)
        router.flush(at: now.addingTimeInterval(1))
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(merged, 1)
    }

    func testUnknownAppsOtherAppsAndAmbiguousSessionsAreNotSwallowed() {
        let router = NotificationRouter(automaticallyFlush: false)
        var shown = 0
        router.onSystem = { _, _ in shown += 1; return true }
        router.receiveAgent(attention(session: "a"), context: context, now: now)
        router.receiveAgent(attention(session: "b"), context: context, now: now)
        router.receiveSystem(content("a", app: "ax.unknown"), now: now)
        router.receiveSystem(content("b", app: "example.mail"), now: now)
        router.receiveSystem(content("c"), now: now)
        router.flush(at: now.addingTimeInterval(1))
        XCTAssertEqual(shown, 3)
    }

    func testExplicitSessionDisambiguatesAndQuestionRequiresMatchingText() {
        var native = content(body: "Approve this change?")
        native.agentSessionID = "a"
        XCTAssertTrue(NotificationRouter.matches(native, attention: attention(session: "a", kind: .question), context: context))
        XCTAssertFalse(NotificationRouter.matches(native, attention: attention(session: "b", kind: .question), context: context))
        native = content(body: "A different question")
        XCTAssertFalse(NotificationRouter.matches(native, attention: attention(kind: .question), context: context))
    }

    func testOldCompletionCannotConsumeNewNotification() {
        let router = NotificationRouter(automaticallyFlush: false)
        var shown = 0
        router.onSystem = { _, _ in shown += 1; return true }
        router.receiveAgent(attention(), context: context, now: now.addingTimeInterval(-20))
        router.receiveSystem(content(), now: now)
        router.flush(at: now.addingTimeInterval(1))
        XCTAssertEqual(shown, 1)
    }

    func testWithheldDeliveryDoesNotTriggerSuppressionOnRedelivery() {
        let router = NotificationRouter(automaticallyFlush: false)
        var redelivered = false
        router.onSystem = { _, _ in false }
        router.onRedelivery = { _ in redelivered = true }
        router.receiveSystem(content("ax:one", record: -1), now: now)
        router.flush(at: now.addingTimeInterval(1))
        router.receiveSystem(content("one"), now: now.addingTimeInterval(2))
        XCTAssertFalse(redelivered)
    }

    func testResetCancelsPendingDelivery() {
        let router = NotificationRouter(automaticallyFlush: false)
        var shown = 0
        router.onSystem = { _, _ in shown += 1; return true }
        router.receiveSystem(content(), now: now)
        router.reset()
        router.flush(at: now.addingTimeInterval(1))
        XCTAssertEqual(shown, 0)
    }

    func testIntegrationCanSupplyUnknownProviderHostWithoutRouterChanges() {
        let supplied = AgentProviderRegistry.notificationContext(source: "future-provider", explicitBundleID: "Example.Agent")
        XCTAssertTrue(NotificationRouter.matches(content(), attention: attention(), context: supplied))
        let terminal = AgentProviderRegistry.notificationContext(source: "claude", host: .terminal)
        XCTAssertFalse(terminal.bundleIDs.contains(AgentSessionJump.claudeBundleID))
        XCTAssertTrue(terminal.bundleIDs.contains("com.apple.terminal"))
    }

    func testGroupedBannerNeverCallsDismissEvenIfCloseIsAdvertised() async {
        let done = expectation(description: "group detected")
        var dismissals = 0
        let suppressor = NativeBannerSuppressor(observe: { _ in .grouped }, dismiss: { _ in dismissals += 1; return true }, retryDelays: [0])
        suppressor.onOutcome = { _, outcome in XCTAssertEqual(outcome, .grouped); done.fulfill() }
        suppressor.suppress(content())
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(suppressor.issues.count, 1)
        XCTAssertTrue(NativeBannerSuppressor.isGrouped(texts: ["Example, Alert, Body, stacked"], actionDescriptions: ["Close"]))
    }

    func testAcceptedCloseIsNotSuccessUntilBannerDisappears() async {
        let done = expectation(description: "still visible")
        let suppressor = NativeBannerSuppressor(observe: { _ in .individual }, dismiss: { _ in true }, retryDelays: [0, 0])
        suppressor.onOutcome = { _, outcome in XCTAssertEqual(outcome, .failed); done.fulfill() }
        suppressor.suppress(content())
        await fulfillment(of: [done], timeout: 2)
    }

    func testVerifiedDisappearanceAndTransportRequestsShareOneDismissal() async {
        let done = expectation(description: "verified")
        var visible = true
        var dismissals = 0
        let suppressor = NativeBannerSuppressor(observe: { _ in visible ? .individual : .absent },
            dismiss: { _ in dismissals += 1; visible = false; return true }, retryDelays: [0, 0])
        suppressor.onOutcome = { _, outcome in XCTAssertEqual(outcome, .verified); done.fulfill() }
        suppressor.suppress(content("one"))
        suppressor.suppress(content("ax:one", record: -1))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(suppressor.issues.isEmpty)
    }
}

final class IslandNotificationTests: XCTestCase {
    @MainActor
    func testNotificationHistoryUsesScrollableRowsInsideCompactModule() {
        let center = IslandNotificationCenter()
        for index in 0..<12 {
            center.rememberQuietly(systemNotification(
                title: "Sender \(index)",
                body: "Message \(index)",
                id: index
            ))
        }

        let host = NSHostingView(rootView: NotificationHistoryView(center: center))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 190)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(containsScrollView(in: host))
    }

    @MainActor
    func testNotificationHistoryCanRemoveOneRecentOrClearAll() {
        let center = IslandNotificationCenter()
        let first = systemNotification(title: "First", body: nil, id: 1)
        let second = systemNotification(title: "Second", body: nil, id: 2)
        center.rememberQuietly(first)
        center.rememberQuietly(second)

        center.forgetRecent(id: first.id)
        XCTAssertEqual(center.recents.map(\.id), [second.id])

        center.forgetAllRecents()
        XCTAssertTrue(center.recents.isEmpty)
    }

    /// Opt-in: draws the compact island and each card with a MacBook notch
    /// marked in red, so content behind the camera housing is visible on a
    /// Mac that has none. Set TEST_RUNNER_NANO_NOTCH_DIR to an output folder.
    @MainActor
    func testRenderNotchStatesWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["NANO_NOTCH_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let notch = CGSize(width: 185, height: 32)
        let notices: [(String, IslandNotification?)] = [
            ("00-compact-agent", nil),
            ("01-volume", .preview(for: .volume)),
            ("02-timer", .preview(for: .timer)),
            ("03-bluetooth", .preview(for: .bluetooth)),
            ("04-battery", .preview(for: .battery)),
            ("05-message", .preview(for: .system)),
            ("06-agent-permission", .agentPreview(provider: .claude, kind: .permission)),
            ("07-agent-question", .agentPreview(provider: .codex, kind: .question)),
            ("08-agent-finished", .agentPreview(provider: .claude, kind: .completion)),
            ("09-agent-setup", .agentSetup(provider: .claude)),
            ("10-update", .update(.preview)),
            ("11-quill-suggestion", .quillSuggestion(VoiceDictationCorrection(
                kind: .changeOfMind, spoken: "actually", written: "", count: 2, lastSeen: Date()
            ))),
        ]
        for (name, notice) in notices {
            let suite = "NanoTests.notch.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = NanoSettings(defaults: defaults)
            settings.placement = .attached
            let model = IslandViewModel(settings: settings)
            model.notchWidth = notch.width
            model.notchHeight = notch.height
            var working = AgentSession(id: "notch", provider: .claude, projectName: "Nano", lastActivityAt: Date())
            working.isActive = true
            model.sessionStore.applyIncrementalSessions([working])
            if let notice { model.previewNotification(notice) }
            let view = NSHostingView(rootView: ZStack(alignment: .top) {
                Color(red: 0.07, green: 0.025, blue: 0.65)
                IslandRootView(settings: settings, viewModel: model)
                Rectangle()
                    .strokeBorder(Color.red, lineWidth: 1)
                    .background(Color.red.opacity(0.25))
                    .frame(width: notch.width, height: notch.height)
            })
            let size = NSSize(width: 820, height: 320)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(900))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(name).png"))
            model.notificationCenter.dismissAll()
        }
    }

    @MainActor
    func testCaptureCompletionMorphWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["NANO_COMPLETION_MORPH_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for placement in IslandPlacement.allCases {
            let suite = "NanoTests.morph.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = NanoSettings(defaults: defaults)
            settings.placement = placement
            settings.appearance = .hybrid
            let model = IslandViewModel(settings: settings)
            model.notchWidth = placement == .attached ? 180 : 0
            var working = AgentSession(id: "background", provider: .codex, projectName: "Background", lastActivityAt: Date())
            working.isActive = true
            model.sessionStore.applyIncrementalSessions([working])
            let view = NSHostingView(rootView: ZStack {
                Color(red: 0.07, green: 0.025, blue: 0.65)
                IslandRootView(settings: settings, viewModel: model)
            })
            let size = NSSize(width: 820, height: 260)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            func capture(_ label: String) throws {
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(placement.rawValue)-\(label).png"))
            }
            try await Task.sleep(for: .milliseconds(200))
            try capture("00-compact")
            model.previewNotification(.agentPreview(provider: .codex, kind: .completion))
            for frame in 1...16 {
                try await Task.sleep(for: .milliseconds(40))
                try capture(String(format: "%02d-expanding", frame))
            }
            model.notificationCenter.dismissAll()
            try await Task.sleep(for: .milliseconds(600))
            try capture("17-restored")
        }
    }

    @MainActor
    func testProviderPreviewsReplaceEachOtherWithoutReplayingOldProvider() {
        let center = IslandNotificationCenter()
        let real = agentRequest(id: "real-permission")
        center.present(real)
        for provider in [AgentProviderID.claude, .grok, .pi, .opencode, .kimi] {
            let preview = IslandNotification.agentPreview(provider: provider, kind: .permission)
            center.presentPreview(preview)
            guard case let .agent(attention) = center.current?.payload else {
                return XCTFail("Missing preview")
            }
            XCTAssertEqual(attention.provider, provider)
            XCTAssertEqual(center.current?.id, preview.id)
        }
        center.dismissCurrent()
        XCTAssertEqual(center.current?.id, real.id)
        center.dismissCurrent()
        XCTAssertNil(center.current)
    }

    @MainActor
    func testNotificationProviderColorsAreDistinct() {
        let providers: [AgentProviderID] = [.grok, .pi, .opencode, .kimi]
        let colors = providers.map { NSColor($0.notificationColor).usingColorSpace(.deviceRGB)! }
        for i in colors.indices {
            for j in colors.indices where j > i { XCTAssertNotEqual(colors[i], colors[j]) }
        }
    }

    func testNotchNotificationOutlineOmitsTopClosingEdge() {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 160)
        var closed = false
        NanoNotchShape(bottomRadius: 24, flare: 12, closesTop: false).path(in: rect).cgPath.applyWithBlock {
            if $0.pointee.type == .closeSubpath { closed = true }
        }
        XCTAssertFalse(closed)
    }

    func testNotchRadiusAndFlareInterpolateTogether() {
        var shape = NanoNotchShape(bottomRadius: 17, flare: 10)
        shape.animatableData = AnimatablePair(20.5, 11)
        XCTAssertEqual(shape.bottomRadius, 20.5)
        XCTAssertEqual(shape.flare, 11)
    }

    @MainActor
    func testNotificationHighlightDoesNotAddAnotherBaseOutline() {
        let stroke = ProviderNotificationStrokeView(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        stroke.configure(tint: .white, animated: true, attached: false, cornerRadius: 17, flare: 0, showsBase: false)
        stroke.layout()
        let visible = stroke.layer?.sublayers?.filter { !$0.isHidden } ?? []
        XCTAssertEqual(visible.count, 1)
        XCTAssertTrue(visible.first === stroke.highlight)
        stroke.frame.size = NSSize(width: 640, height: 160)
        stroke.layout()
        XCTAssertNil(stroke.highlight.animation(forKey: "path"))
        XCTAssertNotNil(stroke.highlight.animation(forKey: "providerStroke"))
    }

    func testSystemNotificationsStayCompactWhileAgentCommandsHaveRoom() {
        for source in IslandNotificationSource.allCases where source != .agent {
            let notice = IslandNotification.preview(for: source)
            // Notification Center cards match the system banner width; the rest stay narrower.
            XCTAssertLessThanOrEqual(notice.preferredSize(notchWidth: 0, attached: false).width, source == .system ? 440 : 420)
            XCTAssertLessThanOrEqual(notice.preferredSize(notchWidth: 0, attached: false).height, 88)
            let notched = notice.preferredSize(notchWidth: 200, attached: true)
            XCTAssertGreaterThanOrEqual(notched.width, 200 + 336 + 44)
        }
        for provider in [AgentProviderID.grok, .pi, .opencode, .kimi, .claude, .codex] {
            let notice = IslandNotification.agentPreview(provider: provider, kind: .permission)
            XCTAssertEqual(notice.contentSize.height, 196)
        }
    }

    @MainActor
    func testSystemPreviewsDoNotQueueEarlierAccessoryPreviews() {
        let center = IslandNotificationCenter()
        center.presentPreview(.preview(for: .bluetooth))
        center.presentPreview(.preview(for: .volume))
        center.dismissCurrent()
        XCTAssertNil(center.current)
    }

    private func systemNotification(title: String, body: String?, id: Int, at date: Date = Date()) -> IslandNotification {
        .system(SystemNotificationContent(
            recordID: Int64(id), uuid: "test-\(id)", bundleID: "com.example.test", appName: "Test",
            title: title, subtitle: nil, body: body, deliveredAt: date
        ), at: date)
    }

    @MainActor
    private func containsScrollView(in view: NSView) -> Bool {
        view is NSScrollView || view.subviews.contains(where: containsScrollView)
    }

    private func agentRequest(
        id: String,
        kind: AgentHookBridge.RequestKind = .permission,
        sessionID: String? = nil,
        at date: Date = Date()
    ) -> IslandNotification {
        .agent(IslandAgentAttention(AgentHookBridge.PendingRequest(
            id: id,
            source: "codex",
            kind: kind,
            title: kind == .completion ? "Fix session names" : "Bash",
            detail: nil,
            options: kind == .permission ? [
                .init(id: 0, label: "Deny"), .init(id: 1, label: "Allow Once"),
            ] : [],
            sessionID: sessionID,
            receivedAt: date
        )), at: date)
    }

    func testAgentAttentionIsFirstComeFirstServe() {
        let first = agentRequest(id: "A")
        let second = agentRequest(id: "B")
        let third = agentRequest(id: "C")
        let afterSecond = IslandNotificationQueue.apply(current: first, queue: [], incoming: second)
        let afterThird = IslandNotificationQueue.apply(
            current: afterSecond.current,
            queue: afterSecond.queue,
            incoming: third
        )

        if case let .agent(attention) = afterThird.current.payload {
            XCTAssertEqual(attention.requestID, "A")
        } else {
            XCTFail("Expected current agent request")
        }
        let firstPop = IslandNotificationQueue.pop(afterThird.queue)
        let secondPop = firstPop.flatMap { IslandNotificationQueue.pop($0.1) }
        if case let .agent(attention) = firstPop?.0.payload {
            XCTAssertEqual(attention.requestID, "B")
        } else {
            XCTFail("Expected second agent request")
        }
        if case let .agent(attention) = secondPop?.0.payload {
            XCTAssertEqual(attention.requestID, "C")
        } else {
            XCTFail("Expected third agent request")
        }
    }

    @MainActor
    func testAgentWaitingCountAndSixSecondCompletionAndUpdate() {
        let center = IslandNotificationCenter()
        center.present(agentRequest(id: "A"))
        center.present(agentRequest(id: "B"))
        center.present(agentRequest(id: "C"))
        XCTAssertEqual(center.queuedAgentCount, 2)

        let completion = agentRequest(id: "done", kind: .completion, sessionID: "session-1")
        let update = agentRequest(id: "update", kind: .notification, sessionID: "session-1")
        XCTAssertEqual(completion.duration, 6)
        XCTAssertEqual(update.duration, 6)
        XCTAssertEqual(completion.contentSize.height, 86)
    }

    func testProviderNeedsInputNotificationStaysUntilTheUserActs() {
        let request = AgentHookBridge.notificationRequest(
            event: [
                "notification_type": "agent_needs_input",
                "message": "Choose a migration route",
                "cwd": "/tmp/Nano",
            ],
            source: "claude",
            sessionID: "session-1"
        )
        let notification = IslandNotification.agent(IslandAgentAttention(request))

        XCTAssertEqual(request.kind, .question)
        XCTAssertFalse(request.respondsThroughBridge)
        XCTAssertTrue(notification.isSticky)
        XCTAssertNil(notification.duration)
        XCTAssertEqual(notification.contentSize.height, 150)
    }

    func testDelayedPermissionNotificationDoesNotClaimItCanAnswerTheProvider() {
        let request = AgentHookBridge.notificationRequest(
            event: [
                "notification_type": "permission_prompt",
                "message": "Claude needs network access",
            ],
            source: "claude",
            sessionID: "session-2"
        )
        let attention = IslandAgentAttention(request)

        XCTAssertEqual(attention.kind, .permission)
        XCTAssertFalse(attention.respondsThroughBridge)
        XCTAssertEqual(attention.headline, "Claude needs network access")
        XCTAssertTrue(attention.options.isEmpty)
    }

    func testProviderAgentCompletedNotificationUsesSixSecondCompletionCard() {
        let request = AgentHookBridge.notificationRequest(
            event: ["notification_type": "agent_completed"],
            source: "claude",
            sessionID: "background-1"
        )
        let notification = IslandNotification.agent(IslandAgentAttention(request))

        XCTAssertEqual(request.kind, .completion)
        XCTAssertEqual(notification.title, "Agent finished")
        XCTAssertEqual(notification.duration, 6)
        XCTAssertFalse(notification.isSticky)
    }

    func testTimerCompletionUsesACompactFiveSecondNotification() {
        let notification = IslandNotification.timerCompletion(
            mode: .focus,
            sessionName: "Deep Work",
            configuredDuration: 25 * 60
        )

        XCTAssertEqual(notification.source, .timer)
        XCTAssertEqual(notification.priority, 75)
        XCTAssertEqual(notification.duration, 5)
        XCTAssertEqual(notification.title, "Focus complete")
        XCTAssertEqual(notification.subtitle, "Deep Work · 25 minutes")
        XCTAssertEqual(
            IslandNotification.timerCompletion(mode: .rest, sessionName: nil, configuredDuration: 300).title,
            "Break's over"
        )
        XCTAssertEqual(notification.contentSize, CGSize(width: 400, height: 40))
    }

    func testAgentPresentationUsesProviderIdentityAndTruthfulControls() throws {
        let claudeApproval = IslandNotification.agentPreview(
            provider: .claude,
            kind: .permission
        )
        let geminiApproval = IslandNotification.agentPreview(
            provider: .gemini,
            kind: .permission
        )
        let claudeQuestion = IslandNotification.agentPreview(
            provider: .claude,
            kind: .question
        )

        guard case let .agent(direct) = claudeApproval.payload,
              case let .agent(passive) = geminiApproval.payload,
              case let .agent(question) = claudeQuestion.payload
        else {
            return XCTFail("Expected agent preview payloads")
        }

        XCTAssertEqual(direct.provider, .claude)
        XCTAssertEqual(direct.providerName, "Claude")
        XCTAssertEqual(direct.statusLabel, "Needs you")
        XCTAssertEqual(direct.displayHeadline, "Claude wants to run a command")
        XCTAssertEqual(
            direct.displayDetail,
            "Run xcodebuild test -project Nano.xcodeproj -scheme Nano."
        )
        XCTAssertTrue(direct.respondsThroughBridge)

        XCTAssertEqual(passive.provider, .gemini)
        XCTAssertEqual(passive.statusLabel, "Needs you")
        XCTAssertEqual(passive.displayHeadline, "Approval waiting in Gemini")
        XCTAssertFalse(passive.respondsThroughBridge)

        XCTAssertEqual(question.statusLabel, "Needs you")
        // At least the old fixed height, and tall enough for the measured text.
        XCTAssertEqual(question.cardHeight, max(206, question.measuredCardHeight))
        XCTAssertEqual(question.options.map(\.label), ["Exact session", "Project"])
        XCTAssertEqual(claudeQuestion.contentSize.width, 640)
    }

    func testQuestionCardHeightScalesForVerticalAnswers() {
        let request = AgentHookBridge.PendingRequest(
            id: "four-options",
            source: "claude",
            kind: .question,
            title: "Choose a route",
            detail: "Pick one option.",
            options: (0..<4).map { .init(id: $0, label: "Option \($0 + 1)") },
            sessionID: "session-1",
            receivedAt: Date()
        )

        let attention = IslandAgentAttention(request)
        XCTAssertEqual(attention.cardHeight, max(126 + 4 * 40, attention.measuredCardHeight))
        XCTAssertGreaterThan(attention.cardHeight, IslandAgentAttention(AgentHookBridge.PendingRequest(
            id: "two-options", source: "claude", kind: .question, title: "Choose a route",
            detail: "Pick one option.", options: (0..<2).map { .init(id: $0, label: "Option \($0 + 1)") },
            sessionID: "session-1", receivedAt: Date()
        )).cardHeight)
    }

    func testTopClearanceAppliesToEveryNotificationTypeInEveryPlacement() {
        var notifications = IslandNotificationSource.allCases.map {
            IslandNotification.preview(for: $0)
        }
        notifications.append(contentsOf: AgentProviderID.supported.flatMap { provider in
            [
                AgentHookBridge.RequestKind.permission,
                .question,
                .completion,
                .notification,
            ].map { kind in
                IslandNotification.agentPreview(provider: provider, kind: kind)
            }
        })

        for notification in notifications {
            XCTAssertEqual(
                notification.preferredSize(notchWidth: 0, attached: true).height,
                notification.contentSize.height + IslandNotification.topContentClearance
            )
            XCTAssertEqual(
                notification.preferredSize(notchWidth: 0, attached: false).height,
                notification.contentSize.height + IslandNotification.topContentClearance
            )
        }
    }

    func testEverySupportedProviderHasAllThreeNotificationPreviews() {
        for provider in AgentProviderID.supported {
            for kind in [
                AgentHookBridge.RequestKind.permission,
                .question,
                .completion,
                .notification,
            ] {
                let notification = IslandNotification.agentPreview(
                    provider: provider,
                    kind: kind
                )
                guard case let .agent(attention) = notification.payload else {
                    return XCTFail("Missing \(kind.rawValue) preview for \(provider.rawValue)")
                }
                XCTAssertEqual(attention.provider, provider)
                XCTAssertFalse(attention.displayHeadline.isEmpty)
                XCTAssertEqual(notification.tint, provider.accentColor)
            }
        }
    }

    func testCompletionsForTheSameSessionCoalesceWhileWaiting() {
        let current = agentRequest(id: "A")
        let first = agentRequest(id: "done-1", kind: .completion, sessionID: "session-1")
        let queued = IslandNotificationQueue.apply(current: current, queue: [], incoming: first)
        let second = agentRequest(id: "done-2", kind: .completion, sessionID: "session-1")
        let outcome = IslandNotificationQueue.apply(
            current: queued.current,
            queue: queued.queue,
            incoming: second
        )

        XCTAssertTrue(outcome.coalesced)
        XCTAssertEqual(outcome.queue.count, 1)
    }

    func testAgentNotificationKindsUseTheirOwnPriority() {
        let approval = agentRequest(id: "approval")
        let completion = agentRequest(id: "completion", kind: .completion)
        let update = agentRequest(id: "update", kind: .notification)

        XCTAssertEqual(approval.priority, 120)
        XCTAssertEqual(completion.priority, 90)
        XCTAssertEqual(update.priority, 85)

        let interrupted = IslandNotificationQueue.apply(
            current: completion,
            queue: [],
            incoming: approval
        )
        XCTAssertEqual(interrupted.current.id, approval.id)
        XCTAssertEqual(interrupted.queue.map(\.id), [completion.id])

        let protected = IslandNotificationQueue.apply(
            current: approval,
            queue: [],
            incoming: completion
        )
        XCTAssertEqual(protected.current.id, approval.id)
        XCTAssertEqual(protected.queue.map(\.id), [completion.id])
    }

    func testPopDropsStaleHUDsBeforePromotingTheNextNotification() {
        let now = Date()
        let staleVolume = IslandNotification.volume(
            level: 0.5,
            muted: false,
            at: now.addingTimeInterval(-5)
        )
        let freshMessage = systemNotification(title: "Ada", body: "Ready", id: 1, at: now.addingTimeInterval(-1))

        let next = IslandNotificationQueue.pop([staleVolume, freshMessage], at: now)

        XCTAssertEqual(next?.0.id, freshMessage.id)
        XCTAssertTrue(next?.1.isEmpty == true)
    }

    func testStickyAgentDecisionDoesNotExpireWhileQueued() {
        let now = Date()
        let approval = agentRequest(
            id: "approval",
            at: now.addingTimeInterval(-3_600)
        )

        let next = IslandNotificationQueue.pop([approval], at: now)

        XCTAssertEqual(next?.0.id, approval.id)
    }

    func testApplyRemovesStaleEntriesBeforeEnforcingTheQueueCap() {
        let now = Date()
        let current = agentRequest(id: "approval", at: now)
        let staleMessages = (0..<IslandNotificationQueue.maxQueued).map { index in
            systemNotification(title: "Sender \(index)", body: nil, id: index, at: now.addingTimeInterval(-61))
        }
        let freshVolume = IslandNotification.volume(level: 0.4, muted: false, at: now)

        let outcome = IslandNotificationQueue.apply(
            current: current,
            queue: staleMessages,
            incoming: freshVolume,
            at: now
        )

        XCTAssertEqual(outcome.current.id, current.id)
        XCTAssertEqual(outcome.queue.map(\.id), [freshVolume.id])
    }

    func testTimerCompletionWaitsBehindBlockingAgentAttention() {
        let approval = agentRequest(id: "approval")
        let timer = IslandNotification.timerCompletion(
            mode: .focus,
            sessionName: nil,
            configuredDuration: 25 * 60
        )

        let outcome = IslandNotificationQueue.apply(
            current: approval,
            queue: [],
            incoming: timer
        )

        XCTAssertEqual(outcome.current.id, approval.id)
        XCTAssertEqual(outcome.queue.map(\.id), [timer.id])
    }

    func testVolumeAndBrightnessCoalesceInPlace() {
        let first = IslandNotification.volume(level: 0.2, muted: false)
        let second = IslandNotification.volume(level: 0.8, muted: false)
        let outcome = IslandNotificationQueue.apply(current: first, queue: [], incoming: second)

        XCTAssertTrue(outcome.coalesced)
        XCTAssertEqual(outcome.queue.count, 0)
        if case let .level(value, muted) = outcome.current.payload {
            XCTAssertEqual(value, 0.8, accuracy: 0.0001)
            XCTAssertFalse(muted)
        } else {
            XCTFail("Expected a volume level payload")
        }
    }

    func testHigherPriorityInterruptsAndQueuesTheCurrentHUD() {
        let volume = IslandNotification.volume(level: 0.4, muted: false)
        let pods = IslandNotification.bluetooth(
            name: "Alex’s AirPods Pro",
            category: .headphones,
            connected: true,
            address: "aa-bb"
        )
        let outcome = IslandNotificationQueue.apply(current: volume, queue: [], incoming: pods)

        XCTAssertFalse(outcome.coalesced)
        XCTAssertEqual(outcome.current.source, .bluetooth)
        XCTAssertEqual(outcome.queue.map(\.source), [.volume])
    }

    func testAppleBluetoothModelsResolveWithoutReplacingGenericAccessories() {
        XCTAssertEqual(
            BluetoothDevicePresentation.resolve(
                name: "Alex’s AirPods Pro",
                category: .headphones
            ),
            .airPodsPro
        )
        XCTAssertEqual(
            BluetoothDevicePresentation.resolve(
                name: "AirPods Max",
                category: .headphones
            ),
            .airPodsMax
        )
        XCTAssertEqual(
            BluetoothDevicePresentation.resolve(
                name: "Magic Keyboard with Touch ID",
                category: .keyboard
            ),
            .magicKeyboard
        )
        XCTAssertEqual(
            BluetoothDevicePresentation.resolve(
                name: "Magic Mouse",
                category: .mouse
            ),
            .magicMouse
        )
        XCTAssertNil(
            BluetoothDevicePresentation.resolve(
                name: "MX Master 3S",
                category: .mouse
            )
        )
        XCTAssertNil(
            BluetoothDevicePresentation.resolve(
                name: "Sony WH-1000XM6",
                category: .headphones
            )
        )
    }

    func testAirPodsBatteryUsesOnlyConnectedMatchingDeviceAndValidValues() throws {
        let data = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"AirPods":{"device_address":"AA-BB-CC-DD-EE-FF","device_batteryLevelLeft":"85%","device_batteryLevelCase":"91%","device_batteryLevelRight":"82%"}}]}]}"#.utf8)
        let levels = try XCTUnwrap(AirPodsBatteryLevels.fromProfiler(data, address: "AA:BB:CC:DD:EE:FF"))
        XCTAssertEqual(levels, AirPodsBatteryLevels(left: 85, caseLevel: 91, right: 82))
        XCTAssertNil(AirPodsBatteryLevels.fromProfiler(data, address: "00:00:00:00:00:00"))
        let disconnected = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "device_connected", with: "device_not_connected").utf8)
        XCTAssertNil(AirPodsBatteryLevels.fromProfiler(disconnected, address: "AA:BB:CC:DD:EE:FF"))
        let partial = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "91%", with: "Unknown").replacingOccurrences(of: "82%", with: "255%").utf8)
        XCTAssertEqual(AirPodsBatteryLevels.fromProfiler(partial, address: "AA:BB:CC:DD:EE:FF"), AirPodsBatteryLevels(left: 85, caseLevel: nil, right: nil))
        for name in ["AirPods Max", "AirPods 4", "Sony WH-1000XM6"] {
            XCTAssertFalse(IslandNotification.bluetooth(name: name, category: .headphones, connected: true, address: "test", battery: levels).showsAirPodsBattery)
        }
        XCTAssertTrue(IslandNotification.bluetooth(name: "AirPods Pro", category: .headphones, connected: true, address: "test", battery: levels).showsAirPodsBattery)
        XCTAssertFalse(IslandNotification.bluetooth(name: "AirPods Pro", category: .headphones, connected: false, address: "test", battery: levels).showsAirPodsBattery)
    }

    func testAirPodsArtRequiresTheSpecificProductName() {
        for name in ["AirPods", "Alex’s AirPods", "AirPods 4", "AirPods Professional", "AirPods Maxine", "Beats Studio Pro", "Sony WH-1000XM6"] {
            XCTAssertNil(BluetoothDevicePresentation.resolve(name: name, category: .headphones), name)
        }
        for name in ["AirPods Pro", "ALEX’S AIRPODS PRO 3", "AirPods Pro2"] {
            XCTAssertEqual(BluetoothDevicePresentation.resolve(name: name, category: .headphones), .airPodsPro, name)
        }
        XCTAssertEqual(BluetoothDevicePresentation.resolve(name: "Alex’s AirPods Max", category: .headphones), .airPodsMax)
        XCTAssertNil(BluetoothDevicePresentation.resolve(name: "AirPods Pro", category: .keyboard))
        XCTAssertNil(BluetoothDevicePresentation.magicKeyboard.approvedAnimationName)
        XCTAssertNil(BluetoothDevicePresentation.magicMouse.approvedAnimationName)
    }

    @MainActor
    func testApprovedDeviceAnimationResourcesAreComplete() throws {
        let appURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appBundle = try XCTUnwrap(Bundle(url: appURL))
        for presentation in [BluetoothDevicePresentation.airPodsPro, .airPodsMax] {
            XCTAssertNotNil(presentation.approvedPoster(bundle: appBundle))
            for frame in 1...217 {
                let url = try XCTUnwrap(presentation.approvedFrameURL(frame, bundle: appBundle))
                let image = try XCTUnwrap(NSImage(contentsOf: url), "Missing frame \(frame) for \(presentation)")
                XCTAssertEqual(image.size, NSSize(width: 192, height: 128))
            }
        }
    }

    func testBluetoothModelNotificationAllowsTheTurntableToFinish() {
        let notification = IslandNotification.bluetooth(
            name: "AirPods Max",
            category: .headphones,
            connected: true,
            address: "preview"
        )

        XCTAssertEqual(notification.duration, 4.8)
        XCTAssertEqual(notification.contentSize, CGSize(width: 420, height: 48))
    }

    func testLowerPriorityWaitsBehindTheCurrentHUD() {
        let pods = IslandNotification.bluetooth(
            name: "AirPods",
            category: .headphones,
            connected: true,
            address: "aa-bb"
        )
        let volume = IslandNotification.volume(level: 0.1, muted: true)
        let outcome = IslandNotificationQueue.apply(current: pods, queue: [], incoming: volume)

        XCTAssertEqual(outcome.current.source, .bluetooth)
        XCTAssertEqual(outcome.queue.map(\.source), [.volume])
    }

    func testQueueCoalescesAWaitingVolumeUpdate() {
        let pods = IslandNotification.bluetooth(
            name: "AirPods",
            category: .headphones,
            connected: true,
            address: "aa-bb"
        )
        let first = IslandNotification.volume(level: 0.1, muted: false)
        let queued = IslandNotificationQueue.apply(current: pods, queue: [], incoming: first)
        let second = IslandNotification.volume(level: 0.9, muted: false)
        let outcome = IslandNotificationQueue.apply(
            current: queued.current,
            queue: queued.queue,
            incoming: second
        )

        XCTAssertTrue(outcome.coalesced)
        XCTAssertEqual(outcome.queue.count, 1)
        if case let .level(value, _) = outcome.queue[0].payload {
            XCTAssertEqual(value, 0.9, accuracy: 0.0001)
        } else {
            XCTFail("Queued volume should have been replaced")
        }
    }

    func testQueueIsCapped() {
        let agent = IslandNotification.agent(
            IslandAgentAttention(
                AgentHookBridge.PendingRequest(
                    id: "r1",
                    source: "claude",
                    kind: .permission,
                    title: "Bash",
                    detail: "ls",
                    options: [],
                    sessionID: nil,
                    receivedAt: Date()
                )
            )
        )
        var current: IslandNotification? = agent
        var queue: [IslandNotification] = []
        for index in 0..<10 {
            let incoming = systemNotification(title: "Ada", body: "Hello \(index)", id: index)
            let outcome = IslandNotificationQueue.apply(
                current: current,
                queue: queue,
                incoming: incoming
            )
            current = outcome.current
            queue = outcome.queue
        }

        XCTAssertEqual(current?.source, .agent)
        XCTAssertEqual(queue.count, IslandNotificationQueue.maxQueued)
    }

    func testQueueCapPreservesOldestWaitingNotifications() {
        let current = agentRequest(id: "A")
        var queue: [IslandNotification] = []
        for index in 0..<10 {
            queue = IslandNotificationQueue.apply(
                current: current,
                queue: queue,
                incoming: systemNotification(title: "Sender \(index)", body: nil, id: index)
            ).queue
        }
        XCTAssertEqual(queue.map(\.title), (0..<IslandNotificationQueue.maxQueued).map {
            "Sender \($0)"
        })
    }

    @MainActor
    func testAnsweredQueuedAgentRequestIsPurgedBeforePromotion() {
        let center = IslandNotificationCenter()
        center.present(agentRequest(id: "A"))
        center.present(agentRequest(id: "B"))
        center.retainPendingAgentRequests(["A"])
        XCTAssertEqual(center.queuedAgentCount, 0)
    }

    @MainActor
    func testResumingASessionClearsOnlyPassiveAttentionForThatSession() {
        let center = IslandNotificationCenter()
        let passive = AgentHookBridge.notificationRequest(
            event: ["notification_type": "idle_prompt"],
            source: "claude",
            sessionID: "session-1"
        )
        center.present(.agent(IslandAgentAttention(passive)))
        center.present(agentRequest(id: "bridge", sessionID: "session-2"))

        center.dismissPassiveAgentAttention(sessionID: "session-1")

        if case let .agent(attention) = center.current?.payload {
            XCTAssertEqual(attention.requestID, "bridge")
            XCTAssertTrue(attention.respondsThroughBridge)
        } else {
            XCTFail("Expected the real bridge request to remain")
        }
    }

    @MainActor
    func testDisablingANotificationSourceRemovesCurrentAndQueuedCards() {
        let center = IslandNotificationCenter()
        center.present(agentRequest(id: "A"))
        center.present(systemNotification(title: "Ada", body: "Hello", id: 1))

        center.retainEnabledSources([.system])

        XCTAssertEqual(center.current?.source, .system)
        XCTAssertEqual(center.queuedAgentCount, 0)
    }

    @MainActor
    func testDismissingAFeatureSourcePromotesTheNextUnrelatedHUD() {
        let center = IslandNotificationCenter()
        let request = AgentHookBridge.PendingRequest(
            id: "agent-to-remove",
            source: "codex",
            kind: .question,
            title: "Continue?",
            detail: nil,
            options: [],
            sessionID: nil,
            receivedAt: Date()
        )
        center.present(.agent(IslandAgentAttention(request)))
        center.present(systemNotification(title: "Ada", body: "Hello", id: 1))

        center.dismiss(source: .agent)

        XCTAssertEqual(center.current?.source, .system)
    }

    func testBatteryAnnouncesOnlyChargingStart() {
        let idle = BatterySnapshot(
            percentage: 41,
            isCharging: false,
            isPluggedIn: false,
            timeRemainingMinutes: 90
        )
        let charging = BatterySnapshot(
            percentage: 41,
            isCharging: true,
            isPluggedIn: true,
            timeRemainingMinutes: nil
        )
        let stillCharging = BatterySnapshot(
            percentage: 42,
            isCharging: true,
            isPluggedIn: true,
            timeRemainingMinutes: nil
        )

        XCTAssertTrue(SystemEventMonitor.shouldAnnounceBattery(previous: idle, current: charging))
        XCTAssertFalse(SystemEventMonitor.shouldAnnounceBattery(previous: charging, current: stillCharging))
        XCTAssertFalse(SystemEventMonitor.shouldAnnounceBattery(previous: charging, current: idle))
        XCTAssertTrue(SystemEventMonitor.shouldAnnounceBattery(previous: nil, current: charging))
        XCTAssertFalse(SystemEventMonitor.shouldAnnounceBattery(previous: nil, current: idle))
    }

    func testMediaKeyParserAcceptsKeyUpAndIgnoresForeignSubtypes() {
        // subtype 8, key 0 (volume up), key-down 0x0A
        let volumeDownPacked = (1 << 16) | (0x0A << 8)
        XCTAssertEqual(
            MediaKeyEvent.parse(subtype: 8, data1: volumeDownPacked)?.kind,
            .volumeDown
        )
        XCTAssertEqual(
            MediaKeyEvent.parse(subtype: 8, data1: (1 << 16) | (0x0B << 8))?.kind,
            .volumeDown
        )
        XCTAssertNil(MediaKeyEvent.parse(subtype: 1, data1: volumeDownPacked))
        XCTAssertEqual(
            MediaKeyEvent.parse(subtype: 8, data1: (2 << 16) | (0x0A << 8))?.kind,
            .brightnessUp
        )
        XCTAssertEqual(
            MediaKeyEvent.parse(subtype: 8, data1: (7 << 16) | (0x0A << 8))?.kind,
            .mute
        )
    }

    func testLaunchDoesNotAnnounceAlreadyConnectedBluetoothDevices() {
        var known: Set<String> = ["aa-bb", "cc-dd"]
        XCTAssertFalse(
            BluetoothLaunchFilter.shouldAnnounceConnect(address: "aa-bb", knownAtStart: &known)
        )
        XCTAssertFalse(known.contains("aa-bb"))
        XCTAssertTrue(
            BluetoothLaunchFilter.shouldAnnounceConnect(address: "aa-bb", knownAtStart: &known),
            "A later reconnect of the same device is a real event"
        )
        XCTAssertTrue(
            BluetoothLaunchFilter.shouldAnnounceConnect(address: "new-device", knownAtStart: &known)
        )
    }

    func testBluetoothClassificationPrefersTheDeviceName() {
        XCTAssertEqual(
            BluetoothAccessoryCategory.classify(name: "Alex’s AirPods Pro", major: 4, minor: 0),
            .headphones
        )
        XCTAssertEqual(
            BluetoothAccessoryCategory.classify(name: "Magic Keyboard", major: 5, minor: 1),
            .keyboard
        )
        XCTAssertEqual(
            BluetoothAccessoryCategory.classify(name: "MX Master 3S", major: 5, minor: 2),
            .mouse
        )
        XCTAssertEqual(
            BluetoothAccessoryCategory.classify(name: "Unknown", major: 1, minor: 0),
            .computer
        )
    }

    func testSystemNotificationTextIsCollapsedAndCapped() {
        XCTAssertEqual(SystemNotificationRecordDecoder.cleaned("  hi\nthere  "), "hi there")
        XCTAssertNil(SystemNotificationRecordDecoder.cleaned("   "))
        let long = String(repeating: "a", count: 200)
        let preview = SystemNotificationRecordDecoder.cleaned(long, limit: 120)
        XCTAssertEqual(preview?.count, 120)
        XCTAssertTrue(preview?.hasSuffix("…") == true)
        XCTAssertEqual(
            systemNotification(title: "Ada", body: "On my way", id: 1).duration, 5,
            "ordinary apps get the short info-tier duration"
        )
        XCTAssertEqual(
            IslandNotification.systemPreview(kind: .message).duration, 8,
            "iMessage cards linger long enough to read and reply"
        )
    }

    func testSystemNotificationRecordDecodesNotificationCenterPlist() throws {
        let plist: [String: Any] = [
            "app": "com.anysphere.sand",
            "date": 811_316_908.47,
            "uuid": Data((0..<16).map { UInt8($0) }),
            "req": [
                "titl": "brandforge",
                "body": "marcus confirmed the site only had jpegs\non black.",
                "iden": "0d7e84f3",
            ] as [String: Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let content = try XCTUnwrap(SystemNotificationRecordDecoder.decode(
            data: data, bundleID: "com.anysphere.sand", recordID: 208, deliveredDate: nil, appName: "Grok Bot"
        ))
        XCTAssertEqual(content.title, "brandforge")
        XCTAssertEqual(content.body, "marcus confirmed the site only had jpegs on black.")
        XCTAssertEqual(content.uuid, "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(content.headline, "brandforge")
        XCTAssertEqual(content.appName, "Grok Bot")
        XCTAssertEqual(content.deliveredAt.timeIntervalSinceReferenceDate, 811_316_908.47, accuracy: 0.01)
        XCTAssertFalse(content.isMessage)

        let empty = try PropertyListSerialization.data(
            fromPropertyList: ["app": "x", "req": [:] as [String: Any]], format: .binary, options: 0
        )
        XCTAssertNil(SystemNotificationRecordDecoder.decode(
            data: empty, bundleID: "x", recordID: 1, deliveredDate: nil, appName: "X"
        ), "A record with no words has nothing to show")
    }

    func testCategoryDecoderReadsActionsAndHumanisesAppleKeys() throws {
        let categories: [[String: Any]] = [
            ["id": "reminder", "opt": 0, "acts": [
                ["op": 0, "id": "complete", "ti": "Complete"],
                ["op": 2, "id": "delete", "ti": "Delete"],
                ["op": 4, "id": "reply", "ti": "Reply", "tibt": "Send", "tiph": "Message"],
            ]],
            ["id": "com.apple.mail.replyDelete", "opt": 2176, "acts": [
                ["op": 0, "id": "com.apple.mail.markAsReadButton", "ti": ["MarkReadNotificationActionTitle", "MarkReadNotificationActionTitle", []]],
            ]],
        ]
        let blob = try PropertyListSerialization.data(fromPropertyList: categories, format: .binary, options: 0)

        let reminder = SystemNotificationCategoryDecoder.actions(in: blob, categoryID: "reminder") { _ in nil }
        XCTAssertEqual(reminder.map(\.title), ["Complete", "Delete", "Reply"])
        XCTAssertEqual(reminder.map(\.isDestructive), [false, true, false])
        XCTAssertEqual(reminder.map(\.wantsText), [false, false, true])

        let mail = SystemNotificationCategoryDecoder.actions(in: blob, categoryID: "com.apple.mail.replyDelete") { _ in nil }
        XCTAssertEqual(mail.map(\.title), ["Mark Read"])
        let localized = SystemNotificationCategoryDecoder.actions(in: blob, categoryID: "com.apple.mail.replyDelete") { _ in "Mark as Read" }
        XCTAssertEqual(localized.map(\.title), ["Mark as Read"])

        XCTAssertTrue(SystemNotificationCategoryDecoder.actions(in: blob, categoryID: "missing") { _ in nil }.isEmpty)
    }

    func testSystemNotificationTiersDriveDurationAndPriority() {
        func content(_ bundle: String) -> SystemNotificationContent {
            SystemNotificationContent(
                recordID: 1, uuid: bundle, bundleID: bundle, appName: bundle,
                title: "t", subtitle: nil, body: "b", deliveredAt: Date()
            )
        }
        let text = IslandNotification.system(content("com.apple.MobileSMS"))
        let slack = IslandNotification.system(content("com.tinyspeck.slackmacgap"))
        let calendar = IslandNotification.system(content("com.apple.iCal"))
        XCTAssertEqual(text.duration, 8)
        XCTAssertEqual(calendar.duration, 8)
        XCTAssertEqual(slack.duration, 5)
        XCTAssertGreaterThan(text.priority, slack.priority)
        XCTAssertLessThan(text.priority, IslandNotificationSource.agent.priority)
    }

    func testGroupMessageHeadlineNamesTheGroupOnce() {
        var content = SystemNotificationContent(
            recordID: 1, uuid: "g", bundleID: "com.apple.MobileSMS", appName: "Messages",
            title: "Ada Lovelace", subtitle: "Family", body: "Dinner at 7?", deliveredAt: Date()
        )
        content.message = SystemNotificationMessageContext(
            chatGUID: "iMessage;+;chat1", handle: nil, isGroup: true, groupName: "Family"
        )
        XCTAssertEqual(content.headline, "Ada Lovelace in Family")
        XCTAssertEqual(content.detail, "Dinner at 7?")

        content.previewHidden = true
        XCTAssertEqual(content.headline, "Messages")
        XCTAssertEqual(content.detail, "New notification")
    }

    func testAttachmentPlaceholderBecomesReadableText() {
        XCTAssertEqual(SystemNotificationRecordDecoder.cleaned("\u{FFFC}"), "Sent an attachment")
        XCTAssertEqual(SystemNotificationRecordDecoder.cleaned("\u{FFFC} look at this"), "Attachment · look at this")
        XCTAssertEqual(SystemNotificationRecordDecoder.cleaned("plain"), "plain")
    }

    func testSummaryContentDescribesStormAndCatchUp() {
        var latest = SystemNotificationContent(
            recordID: 9, uuid: "x", bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            title: "#general", subtitle: nil, body: "lunch?", deliveredAt: Date()
        )
        latest.summary = SystemNotificationSummary(kind: .storm, count: 6)
        let storm = IslandViewModel.summaryContent(latest, title: "6 more from Slack")
        XCTAssertEqual(storm.headline, "6 more from Slack")
        XCTAssertEqual(storm.appName, "Slack")
        XCTAssertEqual(storm.tier, .important)
        XCTAssertFalse(storm.isRealRecord)

        latest.summary = SystemNotificationSummary(kind: .catchUp, count: 4)
        let away = IslandViewModel.summaryContent(latest, title: "4 notifications from 2 apps")
        XCTAssertEqual(away.appName, "While you were away")
        XCTAssertEqual(away.detail, "Latest: Slack · #general")
    }

    func testDominantColorFindsTheBrandHueAndSkipsGreyIcons() {
        func icon(_ color: NSColor) -> NSImage {
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
            image.unlockFocus()
            return image
        }
        let blue = SystemNotificationAppInfo.dominantColor(of: icon(NSColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1)))
        XCTAssertNotNil(blue)
        XCTAssertGreaterThan(blue!.blueComponent, blue!.redComponent)
        XCTAssertNil(SystemNotificationAppInfo.dominantColor(of: icon(.gray)))
    }

    func testIncomingCallBannerParserReadsCallerAndKind() {
        let video = IncomingCallBanner.parse(
            texts: ["FaceTime Video", "Ada Lovelace"], buttons: ["Decline", "Accept"]
        )
        XCTAssertEqual(video, IncomingCallBanner(caller: "Ada Lovelace", kind: .faceTimeVideo))

        let audio = IncomingCallBanner.parse(
            texts: ["Callum Reyes", "FaceTime Audio"], buttons: ["Accept", "Decline"]
        )
        XCTAssertEqual(audio?.caller, "Callum Reyes")
        XCTAssertEqual(audio?.kind, .faceTimeAudio)

        let phone = IncomingCallBanner.parse(
            texts: ["Incoming call from iPhone", "+1 (555) 010-0199"], buttons: ["Accept", "Decline"]
        )
        XCTAssertEqual(phone?.caller, "+1 (555) 010-0199")
        XCTAssertEqual(phone?.kind, .phone)
        XCTAssertEqual(phone?.kind.bundleID, "com.apple.mobilephone")

        // Regular banners never have both buttons.
        XCTAssertNil(IncomingCallBanner.parse(texts: ["Messages", "Ada", "hi"], buttons: ["Reply", "Close"]))
        XCTAssertNil(IncomingCallBanner.parse(texts: ["Anything"], buttons: ["Accept"]))
    }

    @MainActor
    func testIncomingCallCardStaysWhileRingingAndClearsByCoalesceKey() {
        let center = IslandNotificationCenter()
        let banner = IncomingCallBanner(caller: "Ada Lovelace", kind: .faceTimeVideo)
        let content = SystemNotificationContent(
            recordID: 0, uuid: "call:test", bundleID: banner.kind.bundleID, appName: banner.kind.appName,
            title: banner.caller, subtitle: nil, body: "Incoming FaceTime Video", deliveredAt: Date()
        )
        let key = IslandViewModel.callCoalesceKey(banner)
        let notification = IslandNotification.system(content, coalesceKey: key)
        XCTAssertEqual(notification.duration, 60)
        XCTAssertEqual(notification.coalesceKey, key)

        center.present(notification)
        XCTAssertEqual(center.current?.coalesceKey, key)
        center.dismiss(coalesceKey: key)
        XCTAssertNil(center.current)
    }

    func testMessagesConversationURLTargetsTheHandle() {
        XCTAssertEqual(
            IslandViewModel.messagesConversationURL(handle: "+1 555 010 0199")?.absoluteString,
            "imessage://+1%20555%20010%200199"
        )
        XCTAssertNil(IslandViewModel.messagesConversationURL(handle: "  "))
    }

    func testSystemNotificationFilterAppliesQuietRules() {
        var filter = SystemNotificationFilter()
        let now = Date()
        func content(_ uuid: String, app: String = "com.example.app", title: String = "Hi", body: String? = "there", age: TimeInterval = 0) -> SystemNotificationContent {
            SystemNotificationContent(
                recordID: 1, uuid: uuid, bundleID: app, appName: "App", title: title, subtitle: nil,
                body: body, deliveredAt: now.addingTimeInterval(-age)
            )
        }

        XCTAssertEqual(filter.admit(content("a"), excludedBundleIDs: [], now: now), .show)
        XCTAssertEqual(filter.admit(content("a"), excludedBundleIDs: [], now: now), .duplicate, "same uuid")
        XCTAssertEqual(filter.admit(content("b"), excludedBundleIDs: [], now: now), .show, "distinct notification IDs preserve repeated messages")
        XCTAssertEqual(filter.admit(content("c", body: "new"), excludedBundleIDs: [], now: now), .show)
        XCTAssertEqual(filter.admit(content("d", age: 120), excludedBundleIDs: [], now: now), .stale)
        XCTAssertEqual(
            filter.admit(content("e", app: "com.muted.app"), excludedBundleIDs: ["COM.MUTED.APP"], now: now),
            .excluded, "exclusion ignores case"
        )

        for index in 0..<6 {
            _ = filter.admit(content("storm-\(index)", app: "com.storm", body: "n\(index)"), excludedBundleIDs: [], now: now)
        }
        XCTAssertEqual(
            filter.admit(content("storm-7", app: "com.storm", body: "n7"), excludedBundleIDs: [], now: now),
            .storm
        )
        XCTAssertEqual(
            filter.admit(content("later", app: "com.storm", body: "later"), excludedBundleIDs: [], now: now.addingTimeInterval(20)),
            .show, "the storm window passes"
        )
    }

    func testMessagesChatResolverPrefersMatchingWordsInsideTheTimeWindow() {
        let delivered = Date()
        let candidates = [
            MessagesChatResolver.Match(chatGUID: "iMessage;-;+1555", handle: "+1555", isGroup: false, text: "Running late", date: delivered.addingTimeInterval(-2)),
            MessagesChatResolver.Match(chatGUID: "iMessage;+;chat9", handle: "+1666", isGroup: true, text: "On my way, save me a seat", date: delivered.addingTimeInterval(-4)),
            MessagesChatResolver.Match(chatGUID: "iMessage;-;+1777", handle: "+1777", isGroup: false, text: "old", date: delivered.addingTimeInterval(-600)),
        ]
        XCTAssertEqual(
            MessagesChatResolver.unambiguousMatch(from: candidates, deliveredAt: delivered, body: "On my way, save me a…")?.chatGUID,
            "iMessage;+;chat9"
        )
        XCTAssertNil(
            MessagesChatResolver.unambiguousMatch(from: candidates, deliveredAt: delivered, body: nil),
            "two chats in the window and no words to separate them"
        )
        XCTAssertEqual(
            MessagesChatResolver.unambiguousMatch(from: [candidates[0], candidates[2]], deliveredAt: delivered, body: nil)?.chatGUID,
            "iMessage;-;+1555"
        )
        let attachment = MessagesChatResolver.Match(chatGUID: "iMessage;-;+1888", handle: "+1888", isGroup: false, text: nil, date: delivered.addingTimeInterval(-1))
        XCTAssertNil(
            MessagesChatResolver.unambiguousMatch(from: [attachment, candidates[0]], deliveredAt: delivered, body: "Something else"),
            "a message without text matches no body"
        )
        XCTAssertNil(MessagesChatResolver.unambiguousMatch(from: [candidates[2]], deliveredAt: delivered, body: nil))
        XCTAssertEqual(
            MessagesChatResolver.messagesDate(700_000_000_000_000_000).timeIntervalSinceReferenceDate, 700_000_000, accuracy: 1
        )
    }

    func testMessagesReplyScriptEscapesQuotesAndBackslashes() {
        let script = MessagesReplySender.script(chatGUID: "iMessage;-;+1555", text: "She said \"hi\" \\ bye")
        XCTAssertTrue(script.contains("chat id \"iMessage;-;+1555\""))
        XCTAssertTrue(script.contains("send \"She said \\\"hi\\\" \\\\ bye\""))
    }

    func testNativeBannerMatchingNeedsTitleAndBodyPrefix() {
        let content = SystemNotificationContent(
            recordID: 1, uuid: "u", bundleID: "com.apple.MobileSMS", appName: "Messages",
            title: "Ada", subtitle: nil, body: "On my way — save me a seat.", deliveredAt: Date()
        )
        XCTAssertTrue(NativeBannerSuppressor.matches(texts: ["Ada", "On my way — save me a seat."], content: content))
        XCTAssertFalse(NativeBannerSuppressor.matches(texts: ["Ada", "Different words entirely"], content: content))
        XCTAssertFalse(NativeBannerSuppressor.matches(texts: ["Grace", "On my way — save me a seat."], content: content))
        XCTAssertFalse(NativeBannerSuppressor.matches(texts: [], content: content))
    }

    func testNativeBannerMatchingFoldsQuotesAndRequiresTheBody() {
        let content = SystemNotificationContent(
            recordID: 1, uuid: "u", bundleID: "com.openai.codex", appName: "ChatGPT",
            title: "Finance - SOL", subtitle: nil,
            body: "If you mean \"are you sure?\": yes. Use GPT-5.6 Sol at high.",
            deliveredAt: Date()
        )
        XCTAssertTrue(
            NativeBannerSuppressor.matches(
                texts: ["Finance - SOL", "If you mean “are you sure?”: yes. Use GPT-5.6 Sol at high."],
                content: content
            )
        )
        XCTAssertFalse(
            NativeBannerSuppressor.matches(
                texts: ["Finance - SOL", "A summarised preview that does not repeat the store body."],
                content: content
            ),
            "a shared conversation title must not dismiss a different message"
        )
        XCTAssertFalse(
            NativeBannerSuppressor.matches(
                texts: ["Something else", "If you mean \"are you sure?\": yes. Use GPT-5.6 Sol at high."],
                content: content
            )
        )
    }

    func testGenericBannerParserReadsChatAlertsAndSkipsTheNotificationCenterPanel() {
        let chatgpt = GenericNotificationBanner.parse(
            texts: [
                "Finance - SOL",
                "If you mean \"are you sure?\": yes. Use GPT-5.6 Sol at high.",
                "now",
            ],
            buttons: ["Close"]
        )
        XCTAssertEqual(chatgpt?.title, "Finance - SOL")
        XCTAssertEqual(chatgpt?.body, "If you mean \"are you sure?\": yes. Use GPT-5.6 Sol at high.")

        XCTAssertNil(
            GenericNotificationBanner.parse(
                texts: ["Finance - SOL", "If you mean \"are you sure?\": yes.", "Edit Widgets"],
                buttons: []
            ),
            "the open Notification Center panel is not a live banner"
        )
        XCTAssertNil(
            GenericNotificationBanner.parse(
                texts: ["Finance - SOL", "If you mean \"are you sure?\": yes."],
                buttons: ["Edit Widgets"]
            ),
            "Edit Widgets as a button still marks the Notification Center panel"
        )
        XCTAssertNil(
            GenericNotificationBanner.parse(
                texts: ["Ada Lovelace", "FaceTime Video"],
                buttons: ["Accept", "Decline"]
            ),
            "call banners stay on the call path"
        )
    }

    func testSystemNotificationsCoalesceByAppAndWordsSoStoreAndAXMerge() {
        let store = SystemNotificationContent(
            recordID: 9, uuid: "store-uuid", bundleID: "com.openai.codex", appName: "ChatGPT",
            title: "Finance - SOL", subtitle: nil, body: "If you mean \"are you sure?\": yes.",
            deliveredAt: Date()
        )
        let ax = SystemNotificationContent(
            recordID: -1, uuid: "ax:finance", bundleID: "com.openai.codex", appName: "ChatGPT",
            title: "Finance - SOL", subtitle: nil, body: "If you mean \"are you sure?\": yes.",
            deliveredAt: Date()
        )
        XCTAssertEqual(
            NotificationIdentity.words(store),
            NotificationIdentity.words(ax)
        )
        XCTAssertNotEqual(store.uuid, ax.uuid)
        let otherApp = SystemNotificationContent(
            recordID: 10, uuid: "other", bundleID: "com.apple.mail", appName: "Mail",
            title: store.title, subtitle: nil, body: store.body, deliveredAt: Date()
        )
        XCTAssertNotEqual(NotificationIdentity.words(store), NotificationIdentity.words(otherApp))
    }

    func testSystemNotificationAppNamesFallBackSensibly() {
        XCTAssertEqual(SystemNotificationAppInfo.fallbackName("com.anysphere.sand"), "Sand")
        XCTAssertEqual(SystemNotificationAppInfo.systemCenterName("com.apple.softwareupdatenotification"), "Software Update")
        XCTAssertEqual(SystemNotificationAppInfo.normalizedBundleID("com.apple.mobilesms"), "com.apple.MobileSMS")
    }

    @MainActor
    func testLegacyMessagesSourceMigratesToSystemNotifications() {
        let suite = "NanoTests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["messages", "volume"], forKey: "notifications.enabledSources")
        let settings = NanoSettings(defaults: defaults)
        XCTAssertTrue(settings.isNotificationEnabled(.system))
        XCTAssertTrue(settings.isNotificationEnabled(.volume))
        XCTAssertFalse(settings.isNotificationEnabled(.battery))
    }

    @MainActor
    func testNativeBannerHidingDefaultsOn() {
        let suite = "NanoTests.hideBanner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NanoSettings(defaults: defaults).systemNotificationsHideNativeBanner)
        defaults.set(false, forKey: "notifications.system.hideNativeBanner")
        XCTAssertFalse(NanoSettings(defaults: defaults).systemNotificationsHideNativeBanner)
    }

    func testVolumeTitleStaysVolumeWhenMuted() {
        let muted = IslandNotification.volume(level: 0, muted: true)
        XCTAssertEqual(muted.title, "Volume")
        XCTAssertEqual(muted.contentSize.height, 40)
    }

    func testBatteryHUDUsesBatteryTitleAndLevelGlyph() {
        let snapshot = BatterySnapshot(
            percentage: 91,
            isCharging: false,
            isPluggedIn: true,
            timeRemainingMinutes: nil
        )
        let hud = IslandNotification.battery(snapshot)
        XCTAssertEqual(hud.title, "Battery")
        XCTAssertEqual(hud.subtitle, "91%")
        XCTAssertEqual(hud.symbol, "battery.100percent")
        XCTAssertEqual(hud.contentSize.height, 40)
    }

    /// Capture the production notification view with its actual bundled poster.
    @MainActor
    func testCaptureBluetoothNotificationFixturesWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["NANO_DEVICE_NOTIFICATION_SNAPSHOT_DIR"] else { return }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var fixtures: [(String, IslandNotification)] = IslandNotificationSource.allCases.filter { $0 != .agent }.map { ($0.rawValue, .preview(for: $0)) }
        for (name, category) in [("AirPods Pro", BluetoothAccessoryCategory.headphones), ("AirPods Max", .headphones), ("Magic Keyboard", .keyboard), ("Magic Mouse", .mouse)] {
            fixtures.append((name, .bluetooth(name: name, category: category, connected: true, address: "snapshot")))
        }
        for provider in [AgentProviderID.grok, .pi, .kimi] {
            fixtures.append((provider.rawValue, .agentPreview(provider: provider, kind: .permission)))
        }
        for placement in IslandPlacement.allCases {
        for (filename, notice) in fixtures {
            let suite = "NanoTests.device-fixture.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = NanoSettings(defaults: defaults)
            settings.placement = placement
            let viewModel = IslandViewModel(settings: settings)
            viewModel.notchWidth = placement == .attached ? 180 : 0
            viewModel.previewNotification(notice)
            let size = viewModel.preferredSize
            let view = NSHostingView(rootView: IslandRootView(settings: settings, viewModel: viewModel))
            view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(placement.rawValue)-\(filename).png"))
        }
    }

    }

    private func sceneViews(in root: NSView) -> [SCNView] {
        root.subviews.flatMap { view in
            (view as? SCNView).map { [$0] } ?? sceneViews(in: view)
        }
    }
}

private struct BluetoothNotificationFixture: View {
    let modelImage: NSImage
    let title: String

    var body: some View {
        GeometryReader { proxy in
            let innerWidth = max(proxy.size.width - 32, 0)
            let sideWidth = max((innerWidth - 88) / 2, 0)

            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    Image(nsImage: modelImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 112, height: 64)
                        .fixedSize()
                        .clipped()
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .frame(width: max(sideWidth - 124, 0), alignment: .leading)
                        .offset(x: 124)
                        .zIndex(1)
                }
                .frame(width: sideWidth, alignment: .leading)

                Color.clear.frame(width: 88)

                Color.clear.frame(width: sideWidth)
            }
            .padding(.horizontal, 16)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(NanoNotchShape(bottomRadius: 22, flare: 12))
        .overlay {
            NanoNotchShape(bottomRadius: 22, flare: 12)
                .stroke(.white.opacity(0.34), lineWidth: 0.75)
        }
        .overlay(alignment: .trailing) {
            Text("Connected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.trailing, 16)
        }
    }
}

@MainActor
final class IslandNotificationRoutingTests: XCTestCase {
    private func viewModel() -> (IslandViewModel, UserDefaults) {
        let suite = "NanoTests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = IslandViewModel(settings: NanoSettings(defaults: defaults))
        model.notificationRouter.holdInterval = 0
        return (model, defaults)
    }

    func testSystemHUDOpensFromIdleAndLeavesHoverAlone() {
        let (viewModel, _) = viewModel()

        viewModel.routeNotification(.volume(level: 0.55, muted: false))
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .volume)

        viewModel.pointerEntered()
        XCTAssertEqual(viewModel.phase, .transientHUD)
    }

    func testSystemHUDTemporarilyOutranksAnOpenAgentDashboard() {
        let (viewModel, _) = viewModel()
        viewModel.openModule(.agents)
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .agents)

        // Volume and other small HUDs dock below an open dashboard now; a
        // system notification still takes the island, which is what this
        // regression test needs.
        viewModel.settings.setNotificationEnabled(true, for: .system)
        viewModel.routeNotification(.system(SystemNotificationContent(
            recordID: 1, uuid: "test-system", bundleID: "com.apple.iCal",
            appName: "Calendar", title: "t", subtitle: nil, body: "b",
            deliveredAt: Date()
        )))
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .system)

        viewModel.notificationCenter.dismissCurrent()
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .agents)
    }

    func testAgentCompletionTemporarilyOutranksAnOpenAgentDashboard() {
        let (viewModel, _) = viewModel()
        viewModel.openModule(.agents)

        viewModel.routeNotification(.agentPreview(provider: .codex, kind: .completion))
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .agent)

        viewModel.notificationCenter.dismissCurrent()
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .agents)
    }

    func testCompletionHUDReturnsToRemainingLiveSessionWithoutNewMessage() throws {
        let (model, _) = viewModel()
        var first = AgentSession(id: "finishing", provider: .codex, projectName: "First", lastActivityAt: Date())
        var second = AgentSession(id: "still-working", provider: .codex, projectName: "Second", lastActivityAt: Date())
        first.isActive = true
        second.isActive = true
        model.sessionStore.applyIncrementalSessions([first, second])
        first.lastActivityAt = first.lastActivityAt.addingTimeInterval(1)
        first.finishedAt = first.lastActivityAt
        first.isActive = false
        model.sessionStore.applyIncrementalSessions([first])
        XCTAssertEqual(model.phase, .transientHUD)
        model.notificationCenter.dismissCurrent()
        XCTAssertEqual(model.phase, .idleCompact)
        XCTAssertEqual(CompactAgentActivitySummary.singleActiveSnapshot(
            snapshots: [], sessions: model.sessionStore.sessions, enabledProviders: [.codex]
        )?.projectName, "Second")

        // Read the latest state, including a second completion during the HUD.
        model.previewNotification(.agentPreview(provider: .codex, kind: .completion))
        second.lastActivityAt = second.lastActivityAt.addingTimeInterval(2)
        second.finishedAt = second.lastActivityAt
        second.isActive = false
        model.sessionStore.applyIncrementalSessions([second])
        model.notificationCenter.dismissAll()
        XCTAssertNil(CompactAgentActivitySummary.singleActiveSnapshot(
            snapshots: [], sessions: model.sessionStore.sessions, enabledProviders: [.codex]
        ))
    }

    func testTranscriptCompletionRoutesThroughTheNotificationHUD() {
        let (viewModel, _) = viewModel()
        let now = Date()
        var working = AgentSession(
            id: "codex-transcript-completion",
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: now
        )
        working.isActive = true
        viewModel.sessionStore.applyIncrementalSessions([working])

        var finished = working
        finished.isActive = false
        finished.lastActivityAt = now.addingTimeInterval(1)
        finished.finishedAt = finished.lastActivityAt
        viewModel.sessionStore.applyIncrementalSessions([finished])

        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .agent)
        guard case let .agent(attention)? = viewModel.notificationCenter.current?.payload else {
            return XCTFail("Expected a provider completion notification")
        }
        XCTAssertEqual(attention.provider, .codex)
    }

    func testAgentAttentionUsesAHUDWhileIdle() {
        let (viewModel, _) = viewModel()
        let request = AgentHookBridge.PendingRequest(
            id: "ask-1",
            source: "claude",
            kind: .permission,
            title: "Bash",
            detail: "ls",
            options: [
                AgentHookBridge.Option(id: 0, label: "Deny"),
                AgentHookBridge.Option(id: 1, label: "Allow Once"),
            ],
            sessionID: nil,
            receivedAt: Date()
        )

        viewModel.presentAgentAttention(request)
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .agent)
        XCTAssertNil(viewModel.activeModule)
    }

    func testAgentAttentionTemporarilyOutranksAnOpenAgentDashboard() {
        let (viewModel, _) = viewModel()
        viewModel.openModule(.agents)
        let request = AgentHookBridge.PendingRequest(
            id: "ask-2",
            source: "claude",
            kind: .question,
            title: "Which file?",
            detail: nil,
            options: [],
            sessionID: nil,
            receivedAt: Date()
        )

        viewModel.presentAgentAttention(request)
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.activeModule, .agents)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .agent)
        XCTAssertTrue(viewModel.notificationCenter.current?.isSticky == true)

        viewModel.notificationCenter.dismissCurrent()
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .agents)
    }

    func testDisabledSourceIsIgnored() {
        let (viewModel, _) = viewModel()
        viewModel.settings.setNotificationEnabled(false, for: .volume)
        viewModel.routeNotification(.volume(level: 1, muted: false))
        XCTAssertEqual(viewModel.phase, .idleCompact)
        XCTAssertNil(viewModel.notificationCenter.current)
    }

    func testDisablingAgentsPreventsAttentionFromOpeningOrDisplaying() {
        let (viewModel, _) = viewModel()
        viewModel.settings.setEnabled(false, for: .agents)
        let request = AgentHookBridge.PendingRequest(
            id: "disabled-agent",
            source: "codex",
            kind: .question,
            title: "Continue?",
            detail: nil,
            options: [],
            sessionID: nil,
            receivedAt: Date()
        )

        viewModel.presentAgentAttention(request)

        XCTAssertEqual(viewModel.phase, .idleCompact)
        XCTAssertNil(viewModel.notificationCenter.current)
        XCTAssertNil(viewModel.activeModule)
    }

    func testDismissingTheHUDReturnsToCompact() {
        let (viewModel, _) = viewModel()
        viewModel.routeNotification(.brightness(level: 0.4))
        XCTAssertEqual(viewModel.phase, .transientHUD)
        viewModel.notificationCenter.dismissCurrent()
        viewModel.collapse()
        XCTAssertEqual(viewModel.phase, .idleCompact)
    }

    func testPreviewShowsAHUDEvenWhenTheSourceIsDisabled() {
        let (viewModel, _) = viewModel()
        viewModel.settings.setNotificationEnabled(false, for: .volume)
        viewModel.previewNotification(.volume)
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .volume)
    }

    func testPreviewRestoresTheDashboardAndModuleThatWasOpen() {
        let (viewModel, _) = viewModel()
        viewModel.openModule(.agents)

        viewModel.previewNotification(.volume)
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.activeModule, .agents)

        viewModel.notificationCenter.dismissCurrent()

        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .agents)
    }

    func testHUDDoesNotRestoreAModuleDisabledWhileNotificationWasVisible() {
        let (viewModel, _) = viewModel()
        viewModel.openModule(.timer)
        viewModel.previewNotification(.volume)
        XCTAssertEqual(viewModel.phase, .transientHUD)

        viewModel.settings.setEnabled(false, for: .timer)
        viewModel.notificationCenter.dismissCurrent()

        XCTAssertNil(viewModel.activeModule)
        XCTAssertEqual(viewModel.phase, .pinnedDashboard, "Preserve the user's open dashboard")
    }

    func testTimerCompletionQueuesBehindApprovalThenReturnsToCompact() throws {
        let (viewModel, _) = viewModel()
        let request = AgentHookBridge.PendingRequest(
            id: "timer-blocker",
            source: "claude",
            kind: .permission,
            title: "Bash",
            detail: "xcodebuild test",
            options: [.init(id: 0, label: "Deny"), .init(id: 1, label: "Allow")],
            sessionID: "session-1",
            receivedAt: Date()
        )
        viewModel.presentAgentAttention(request)
        viewModel.timerStore.sessionName = "Deep Work"
        viewModel.announceTimerCompletion()

        XCTAssertEqual(viewModel.notificationCenter.current?.source, .agent)

        viewModel.notificationCenter.dismissCurrent()
        let timer = try XCTUnwrap(viewModel.notificationCenter.current)
        XCTAssertEqual(timer.source, .timer)
        XCTAssertEqual(timer.subtitle, "Deep Work · 25 minutes")

        viewModel.notificationCenter.dismissCurrent()
        XCTAssertEqual(viewModel.phase, .idleCompact)
        XCTAssertNil(viewModel.activeModule)
    }

    func testTappingTimerCompletionOpensTimerModule() throws {
        let (viewModel, _) = viewModel()
        viewModel.announceTimerCompletion()
        let notification = try XCTUnwrap(viewModel.notificationCenter.current)

        viewModel.handleNotificationTap(notification)

        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .timer)
        XCTAssertNil(viewModel.notificationCenter.current)
    }

    func testTimerCompletionRestoresThePreviouslyOpenModule() {
        let (viewModel, _) = viewModel()
        viewModel.openModule(.agents)

        viewModel.announceTimerCompletion()
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .timer)

        viewModel.notificationCenter.dismissCurrent()

        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.activeModule, .agents)
    }

    func testAXBannerWithoutAStoreRecordStillReachesTheIsland() {
        let (viewModel, _) = viewModel()
        viewModel.settings.setNotificationEnabled(true, for: .system)
        let banner = GenericNotificationBanner.parse(
            texts: [
                "Finance - SOL",
                "If you mean \"are you sure?\": yes. Use GPT-5.6 Sol at high.",
            ],
            buttons: ["Close"]
        )
        XCTAssertNotNil(banner)
        viewModel.handleAXSystemBanner(banner!)
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .system)
        XCTAssertEqual(viewModel.notificationCenter.current?.title, "Finance - SOL")
    }

    func testAXBannerAndStoreRecordCoalesceInsteadOfStacking() {
        let (viewModel, _) = viewModel()
        viewModel.settings.setNotificationEnabled(true, for: .system)
        let banner = GenericNotificationBanner.parse(
            texts: ["ChatGPT, Finance - SOL, If you mean \"are you sure?\": yes., stacked"],
            buttons: ["Close"]
        )!
        viewModel.handleAXSystemBanner(banner)
        viewModel.handleSystemNotification(
            SystemNotificationContent(
                recordID: 12, uuid: "store-1", bundleID: "com.openai.codex", appName: "ChatGPT",
                title: "Finance - SOL", subtitle: nil, body: "If you mean \"are you sure?\": yes.",
                deliveredAt: Date()
            )
        )
        XCTAssertEqual(viewModel.notificationCenter.current?.title, "Finance - SOL")
        viewModel.notificationCenter.dismissCurrent()
        XCTAssertNil(viewModel.notificationCenter.current)
    }
    func testCombinedBannerDescriptionPreservesAppAndDropsRepeatedChild() {
        let banner = GenericNotificationBanner.parse(texts: [
            "ChatGPT, Investigate alerts, Finished, with details., stacked",
            "Investigate alerts Finished, with details."
        ], buttons: [])!
        XCTAssertEqual(banner.title, "Investigate alerts")
        XCTAssertEqual(banner.body, "Finished, with details.")
        XCTAssertEqual(banner.texts.first, "ChatGPT")
    }

    func testDismissalNeverUsesClearAll() {
        XCTAssertFalse(NativeBannerSuppressor.isIndividualDismissAction(name: "AXClose", description: "Clear All"))
        XCTAssertTrue(NativeBannerSuppressor.isIndividualDismissAction(name: "AXClose", description: "Close"))
        XCTAssertFalse(NativeBannerSuppressor.isIndividualDismissAction(name: "Reply", description: "Reply"))
    }

    func testAgentCardWinsOverMatchingNativeCompletionInEitherOrder() {
        for nativeFirst in [true, false] {
            let (model, _) = viewModel()
            model.settings.setNotificationEnabled(true, for: .system)
            model.settings.setNotificationEnabled(true, for: .agent)
            let content = SystemNotificationContent(recordID: 1, uuid: "test", bundleID: "com.openai.codex",
                appName: "ChatGPT", title: "Investigate alerts", subtitle: nil, body: "Done", deliveredAt: Date())
            let request = AgentHookBridge.PendingRequest(id: "test", source: "codex", kind: .completion,
                title: "Investigate alerts", detail: "Ready for review", options: [], sessionID: "session", receivedAt: Date())
            if nativeFirst { model.handleSystemNotification(content) }
            model.routeNotification(.agent(IslandAgentAttention(request)))
            if !nativeFirst { model.handleSystemNotification(content) }
            XCTAssertEqual(model.notificationCenter.current?.source, .agent)
            model.notificationCenter.dismissCurrent()
            XCTAssertNil(model.notificationCenter.current)
        }
    }

    func testAgentCorrelationDoesNotSwallowOtherAppsOrQuestions() {
        let attention = IslandAgentAttention(AgentHookBridge.PendingRequest(id: "test", source: "codex", kind: .question,
            title: "Investigate alerts", detail: "Approve?", options: [], sessionID: "session", receivedAt: Date()))
        let unrelated = SystemNotificationContent(recordID: 1, uuid: "test", bundleID: "com.apple.mail",
            appName: "Mail", title: "Investigate alerts", subtitle: nil, body: "Approve?", deliveredAt: Date())
        XCTAssertFalse(NotificationRouter.matches(unrelated, attention: attention, context: AgentProviderRegistry.notificationContext(source: attention.source)))
        let differentBody = SystemNotificationContent(recordID: 2, uuid: "test2", bundleID: "com.openai.codex",
            appName: "ChatGPT", title: "Investigate alerts", subtitle: nil, body: "Another question", deliveredAt: Date())
        XCTAssertFalse(NotificationRouter.matches(differentBody, attention: attention, context: AgentProviderRegistry.notificationContext(source: attention.source)))
    }

    func testUngroupedBannerWithWindowChromeResolvesItsAppAndContent() {
        let banner = GenericNotificationBanner.parse(texts: [
            "Notification Center",
            "ChatGPT, Investigate duplicate Codex alerts, Nano installed suppression test H complete.",
            "Investigate duplicate Codex alerts Nano installed suppression test H complete."
        ], buttons: [])!
        XCTAssertEqual(banner.title, "Investigate duplicate Codex alerts")
        XCTAssertEqual(banner.body, "Nano installed suppression test H complete.")
        XCTAssertEqual(banner.texts.first, "ChatGPT")
    }

}
