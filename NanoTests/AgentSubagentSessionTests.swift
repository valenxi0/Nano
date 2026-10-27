import XCTest
@testable import Nano

/// Hosts such as T3 run a delegated subagent as a separate agent session. Those
/// children fold into the session that delegated them instead of taking rows
/// of their own.
final class AgentSubagentSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoSubagentTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let brief = """
    Fix one UI bug in the demo app. Your worktree starts at `main`. Create branch \
    `fix-chat-width`. Do NOT commit; leave the change in the worktree.
    """

    private func links() -> AgentSubagentLinks {
        AgentSubagentLinks(storeURL: root.appendingPathComponent("links-\(UUID().uuidString).json"))
    }

    @MainActor
    private func bridge(_ links: AgentSubagentLinks) -> AgentHookBridge {
        let bridge = AgentHookBridge()
        bridge.subagentLinks = links
        return bridge
    }

    @MainActor
    private func send(
        _ bridge: AgentHookBridge,
        _ name: String,
        session: String,
        extra: [String: Any] = [:],
        payload: [String: Any] = [:]
    ) async throws {
        var event: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/tmp/project"]
        event.merge(extra) { $1 }
        var message: [String: Any] = ["source": "claude", "event": event]
        message.merge(payload) { $1 }
        _ = await bridge.handle(try JSONSerialization.data(withJSONObject: message))
    }

    private func delegation(_ task: String) -> [String: Any] {
        [
            "tool_name": "mcp__t3-code__delegate_task",
            "tool_input": ["title": "Fix: chat width", "mode": "async", "task": task],
        ]
    }

    // MARK: - Linking

    @MainActor
    func testChildWhosePromptCarriesTheBriefIsLinkedToItsParent() async throws {
        let parent = "parent-\(UUID().uuidString)"
        let child = "child-\(UUID().uuidString)"
        let store = links()
        let bridge = bridge(store)

        try await send(bridge, "UserPromptSubmit", session: parent, extra: ["prompt": "build the fix"])
        try await send(bridge, "PreToolUse", session: parent, extra: delegation(brief))
        try await send(bridge, "UserPromptSubmit", session: child, extra: [
            "prompt": "Act as the implementation sub-agent for this task.\n\n" + brief,
        ])

        XCTAssertEqual(bridge.sessionStates[child]?.parentSessionID, parent)
        XCTAssertNil(bridge.sessionStates[parent]?.parentSessionID)
        XCTAssertEqual(store.parent(of: child), parent)
        XCTAssertTrue(bridge.pendingDelegations.isEmpty, "a delegation links one child")
    }

    @MainActor
    func testChildThatStartsBeforeTheDelegationArrivesIsStillLinked() async throws {
        let parent = "parent-\(UUID().uuidString)"
        let child = "child-\(UUID().uuidString)"
        let store = links()
        let bridge = bridge(store)

        try await send(bridge, "UserPromptSubmit", session: parent, extra: ["prompt": "build the fix"])
        try await send(bridge, "UserPromptSubmit", session: child, extra: ["prompt": brief])
        XCTAssertNil(bridge.sessionStates[child]?.parentSessionID)

        // Only the post-tool event, as a host without pre-tool hooks sends.
        try await send(bridge, "PostToolUse", session: parent, extra: delegation(brief))

        XCTAssertEqual(bridge.sessionStates[child]?.parentSessionID, parent)
        XCTAssertEqual(store.parent(of: child), parent)
    }

    @MainActor
    func testPostToolEventOfAMatchedDelegationDoesNotWaitForAnotherChild() async throws {
        let parent = "parent-\(UUID().uuidString)"
        let child = "child-\(UUID().uuidString)"
        let bridge = bridge(links())

        try await send(bridge, "PreToolUse", session: parent, extra: delegation(brief))
        try await send(bridge, "UserPromptSubmit", session: child, extra: ["prompt": brief])
        try await send(bridge, "PostToolUse", session: parent, extra: delegation(brief))

        XCTAssertTrue(bridge.pendingDelegations.isEmpty)
    }

    @MainActor
    func testLauncherCanNameTheParentInTheEnvironment() async throws {
        let child = "child-\(UUID().uuidString)"
        let store = links()
        let bridge = bridge(store)

        try await send(
            bridge, "UserPromptSubmit", session: child,
            extra: ["prompt": "summarise the inbox"],
            payload: ["parent_session_id": "launcher-run-42"]
        )

        XCTAssertEqual(bridge.sessionStates[child]?.parentSessionID, "launcher-run-42")
        XCTAssertEqual(store.parent(of: child), "launcher-run-42")
    }

    @MainActor
    func testUnrelatedSessionIsNotLinked() async throws {
        let parent = "parent-\(UUID().uuidString)"
        let other = "other-\(UUID().uuidString)"
        let bridge = bridge(links())

        try await send(bridge, "PreToolUse", session: parent, extra: delegation(brief))
        try await send(bridge, "UserPromptSubmit", session: other, extra: [
            "prompt": "Look at the failing settings tests and tell me why they broke.",
        ])

        XCTAssertNil(bridge.sessionStates[other]?.parentSessionID)
        XCTAssertEqual(bridge.pendingDelegations.count, 1)
    }

    @MainActor
    func testLaterPromptOfAnExistingSessionIsNotTakenForAChild() async throws {
        let parent = "parent-\(UUID().uuidString)"
        let existing = "existing-\(UUID().uuidString)"
        let bridge = bridge(links())

        try await send(bridge, "UserPromptSubmit", session: existing, extra: ["prompt": "hello there, first message"])
        try await send(bridge, "PreToolUse", session: parent, extra: delegation(brief))
        try await send(bridge, "UserPromptSubmit", session: existing, extra: ["prompt": brief])

        XCTAssertNil(bridge.sessionStates[existing]?.parentSessionID)
    }

    func testDelegationToolsAndBriefs() {
        XCTAssertTrue(AgentHookBridge.isDelegationTool("mcp__t3-code__delegate_task"))
        XCTAssertTrue(AgentHookBridge.isDelegationTool("spawn_agent"))
        XCTAssertTrue(AgentHookBridge.isDelegationTool("Task"))
        XCTAssertTrue(AgentHookBridge.isDelegationTool("Agent"))
        XCTAssertTrue(AgentHookBridge.isDelegationTool("mcp__launcher__start_subagent"))
        XCTAssertFalse(AgentHookBridge.isDelegationTool("Bash"))
        XCTAssertFalse(AgentHookBridge.isDelegationTool("mcp__t3-code__task_status"),
                       "only the last segment counts, and task_status is not a delegation")

        XCTAssertNil(AgentHookBridge.delegationBrief(tool: "Bash", input: ["command": brief]))
        XCTAssertNil(AgentHookBridge.delegationBrief(tool: "Task", input: ["prompt": "too short"]))
        XCTAssertEqual(
            AgentHookBridge.delegationBrief(tool: "Task", input: ["prompt": "Read   the\nlogs and report back to me"]),
            "Read the logs and report back to me"
        )
    }

    func testExpiredDelegationDoesNotMatch() {
        let now = Date()
        let delegations = [
            AgentHookBridge.PendingDelegation(
                parentSessionID: "parent",
                brief: AgentHookBridge.normalizedBrief(brief),
                at: now.addingTimeInterval(-AgentHookBridge.delegationWindow - 1)
            ),
        ]
        XCTAssertNil(AgentHookBridge.delegationIndex(matching: brief, in: delegations, excluding: "child", at: now))
        XCTAssertEqual(
            AgentHookBridge.delegationIndex(
                matching: brief, in: delegations, excluding: "child",
                at: now.addingTimeInterval(-60)
            ),
            0
        )
    }

    func testLinksSurviveARestart() {
        let url = root.appendingPathComponent("links.json")
        AgentSubagentLinks(storeURL: url).link(child: "child", to: "parent")
        XCTAssertEqual(AgentSubagentLinks(storeURL: url).parent(of: "child"), "parent")
        XCTAssertNil(AgentSubagentLinks(storeURL: url).parent(of: "parent"))
    }

    // MARK: - The session list

    private func state(
        _ id: String,
        working: Bool,
        parent: String? = nil,
        lastEvent: Date = Date()
    ) -> AgentHookBridge.LiveSessionState {
        var state = AgentHookBridge.LiveSessionState(
            sessionID: id,
            source: "claude",
            firstSeen: lastEvent.addingTimeInterval(-600),
            lastEventAt: lastEvent,
            isWorking: working
        )
        state.lastUserPrompt = "work on \(id)"
        state.parentSessionID = parent
        if !working { state.finishedAt = lastEvent }
        return state
    }

    @MainActor
    func testChildSessionsFoldIntoTheirParentsRow() {
        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: links())
        let states = [
            "parent": state("parent", working: true),
            "child-a": state("child-a", working: true, parent: "parent"),
            "child-b": state("child-b", working: false, parent: "parent"),
        ]
        store.applyHookState(states, t3Runtime: AgentT3RuntimeIndex())

        let live = store.liveSessions
        XCTAssertEqual(live.map(\.id), ["parent"])
        XCTAssertEqual(live.first?.subagentCount, 2)
        XCTAssertEqual(live.first?.subagentsWorking, 1)
        XCTAssertEqual(store.childSessions(of: "parent").map(\.id).sorted(), ["child-a", "child-b"])
        let child = try? XCTUnwrap(store.sessions.first { $0.id == "child-a" })
        XCTAssertEqual(child.flatMap { store.parentSession(of: $0) }?.id, "parent")
    }

    @MainActor
    func testChildThatNeedsTheUserKeepsARowNamingItsParent() {
        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: links())
        store.applyHookState([
            "parent": state("parent", working: true),
            "child": state("child", working: true, parent: "parent"),
        ], t3Runtime: AgentT3RuntimeIndex())
        store.applyLiveSignals([:], waiting: ["child"])

        let child = store.liveSessions.first { $0.id == "child" }
        XCTAssertNotNil(child)
        XCTAssertEqual(child?.parentTitle, "work on parent")
    }

    @MainActor
    func testParentStaysWhileItsSubagentsWork() {
        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: links())
        let old = Date().addingTimeInterval(-(AgentSessionStore.lingerWindow + 600))
        store.applyHookState([
            "parent": state("parent", working: false, lastEvent: old),
            "child": state("child", working: true, parent: "parent"),
        ], t3Runtime: AgentT3RuntimeIndex())

        XCTAssertEqual(store.liveSessions.map(\.id), ["parent"])
    }

    @MainActor
    func testChildOfAnUnknownParentKeepsItsOwnRow() {
        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: links())
        store.applyHookState([
            "child": state("child", working: true, parent: "not-a-session"),
        ], t3Runtime: AgentT3RuntimeIndex())

        XCTAssertEqual(store.liveSessions.map(\.id), ["child"])
    }

    @MainActor
    func testSavedLinkFoldsAChildWithoutHookState() {
        let saved = links()
        saved.link(child: "child", to: "parent")
        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: saved)
        store.applyHookState([
            "parent": state("parent", working: true),
            "child": state("child", working: true),
        ], t3Runtime: AgentT3RuntimeIndex())

        XCTAssertEqual(store.liveSessions.map(\.id), ["parent"])
    }

    // MARK: - Subagents section

    func testEntriesCoverTranscriptSubagentsAndChildSessions() {
        let now = Date()
        var parent = AgentSession(id: "parent", provider: .claude, projectName: "p", lastActivityAt: now)
        parent.isActive = true
        parent.subagents = [
            AgentSubagent(type: "Explore", task: "Find the chart code", toolUseID: "t1", startedAt: now.addingTimeInterval(-100)),
            AgentSubagent(type: "general-purpose", task: "Write tests", toolUseID: "t2",
                          startedAt: now.addingTimeInterval(-300), finishedAt: now.addingTimeInterval(-120)),
        ]
        var child = AgentSession(id: "child", provider: .claude, projectName: "p", lastActivityAt: now)
        child.startedAt = now.addingTimeInterval(-2000)
        child.finishedAt = now.addingTimeInterval(-240)
        child.model = "claude-opus-5-5"

        let entries = AgentSubagentEntry.entries(for: parent, children: [child])
        XCTAssertEqual(entries.map(\.status), [.working, .done, .done])
        XCTAssertNil(entries[0].sessionID)
        XCTAssertEqual(entries[2].sessionID, "child")
        XCTAssertEqual(entries[0].timeLabel(now: now), "1m 40s")
        XCTAssertEqual(entries[1].timeLabel(now: now), "done 2m ago \u{00B7} 3m 0s")
        XCTAssertEqual(entries[2].timeLabel(now: now), "done 4m ago \u{00B7} 29m 20s")
    }

    func testTranscriptSubagentFinishesOnItsToolResult() {
        let start = Date()
        var subagents = [AgentSubagent(type: "Explore", task: "Look", toolUseID: "toolu_1", startedAt: start)]
        AgentSubagent.complete(&subagents, from: [
            ["type": "tool_result", "tool_use_id": "toolu_other"],
        ], at: start.addingTimeInterval(5))
        XCTAssertNil(subagents[0].finishedAt)

        AgentSubagent.complete(&subagents, from: [
            ["type": "tool_result", "tool_use_id": "toolu_1", "is_error": true],
        ], at: start.addingTimeInterval(30))
        XCTAssertEqual(subagents[0].finishedAt, start.addingTimeInterval(30))
        XCTAssertTrue(subagents[0].failed)
    }

    func testSubagentThatReturnedAtOnceShowsNoRunTime() {
        let now = Date()
        var parent = AgentSession(id: "parent", provider: .claude, projectName: "p", lastActivityAt: now)
        let finished = now.addingTimeInterval(-3600)
        parent.subagents = [
            AgentSubagent(type: "general-purpose", task: "Spec R2", toolUseID: "t", startedAt: finished, finishedAt: finished),
        ]
        let entry = AgentSubagentEntry.entries(for: parent, children: [])[0]
        XCTAssertEqual(entry.timeLabel(now: now), "done 1h ago")
    }

    func testBackgroundSubagentRunsUntilItsNotification() {
        let start = Date().addingTimeInterval(-600)
        var subagents = [AgentSubagent(
            type: "general-purpose", task: "Provision VM", toolUseID: "toolu_bg", startedAt: start, isBackground: true
        )]
        AgentSubagent.complete(&subagents, from: [[
            "type": "tool_result", "tool_use_id": "toolu_bg",
            "content": [["type": "text", "text": "Async agent launched successfully.\nagentId: a1"]],
        ]], at: start.addingTimeInterval(1))
        XCTAssertNil(subagents[0].finishedAt, "the launch receipt is not the end")
        XCTAssertTrue(subagents[0].isRunning(parentActive: false), "it outlives the parent's turn")

        AgentSubagent.applyNotifications(in: """
        <task-notification>
        <task-id>a1</task-id>
        <tool-use-id>toolu_bg</tool-use-id>
        <status>completed</status>
        <summary>Agent "Provision VM" finished</summary>
        </task-notification>
        """, at: start.addingTimeInterval(300), to: &subagents)
        XCTAssertEqual(subagents[0].finishedAt, start.addingTimeInterval(300))
        XCTAssertFalse(subagents[0].isRunning(parentActive: true))
    }

    func testKilledBackgroundSubagentReadsAsStopped() {
        let start = Date().addingTimeInterval(-60)
        var subagents = [AgentSubagent(type: "Explore", task: "Look", toolUseID: "t", startedAt: start, isBackground: true)]
        AgentSubagent.applyNotifications(
            in: "<task-notification><tool-use-id>t</tool-use-id><status>killed</status></task-notification>",
            at: start.addingTimeInterval(30),
            to: &subagents
        )
        var parent = AgentSession(id: "p", provider: .claude, projectName: "p", lastActivityAt: start)
        parent.subagents = subagents
        XCTAssertEqual(AgentSubagentEntry.entries(for: parent, children: []).first?.status, .stopped)
    }

    @MainActor
    func testParentRowCountsBuiltInSubagents() {
        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: links())
        let start = Date().addingTimeInterval(-120)
        var parent = AgentSession(id: "parent", provider: .claude, projectName: "p", lastActivityAt: Date())
        parent.lastUserPrompt = "verify the build"
        parent.subagents = [
            AgentSubagent(type: "general-purpose", task: "Provision VM", toolUseID: "a", startedAt: start, isBackground: true),
            AgentSubagent(type: "Explore", task: "Look", toolUseID: "b", startedAt: start, finishedAt: start.addingTimeInterval(30)),
        ]
        store.applyIncrementalSessions([parent])

        let row = store.liveSessions.first { $0.id == "parent" }
        XCTAssertEqual(row?.subagentCount, 2)
        XCTAssertEqual(row?.subagentsWorking, 1)
    }

    @MainActor
    func testSubagentHooksKeepTheParentsCountLive() async throws {
        let parent = "parent-\(UUID().uuidString)"
        let transcript = root.appendingPathComponent("\(parent).jsonl")
        let metaFolder = root.appendingPathComponent("\(parent)/subagents")
        try FileManager.default.createDirectory(at: metaFolder, withIntermediateDirectories: true)
        try Data(#"{"agentType":"Explore","description":"Map code for Code Review","toolUseId":"toolu_9","requestShape":"foreground"}"#.utf8)
            .write(to: metaFolder.appendingPathComponent("agent-a80.meta.json"))
        let bridge = bridge(links())
        let path = ["transcript_path": transcript.path]

        try await send(bridge, "UserPromptSubmit", session: parent, extra: path.merging(["prompt": "plan code review"]) { $1 })
        try await send(bridge, "SubagentStart", session: parent, extra: path.merging(["agent_id": "a80", "agent_type": "Explore"]) { $1 })

        let started = try XCTUnwrap(bridge.sessionStates[parent]?.subagents.first)
        XCTAssertEqual(started.description, "Map code for Code Review")
        XCTAssertEqual(started.toolUseID, "toolu_9")
        XCTAssertNil(started.finishedAt)

        let store = AgentSessionStore(dismissalsURL: nil, subagentLinks: links())
        store.applyHookState(bridge.sessionStates, t3Runtime: AgentT3RuntimeIndex())
        var row = store.liveSessions.first { $0.id == parent }
        XCTAssertEqual(row?.subagentCount, 1)
        XCTAssertEqual(row?.subagentsWorking, 1)

        try await send(bridge, "SubagentStop", session: parent, extra: path.merging(["agent_id": "a80", "agent_type": "Explore"]) { $1 })
        store.applyHookState(bridge.sessionStates, t3Runtime: AgentT3RuntimeIndex())
        row = store.liveSessions.first { $0.id == parent }
        XCTAssertEqual(row?.subagentCount, 1)
        XCTAssertEqual(row?.subagentsWorking, 0)
    }

    func testHookSubagentMatchesTheTranscriptsByToolCall() {
        var subagents = [AgentSubagent(type: "Explore", task: "Map code", toolUseID: "toolu_9", startedAt: Date())]
        let live = AgentHookBridge.LiveSubagent(
            agentID: "a80", type: "Explore", description: "Map code", toolUseID: "toolu_9",
            startedAt: Date(), finishedAt: Date()
        )
        XCTAssertTrue(AgentSubagent.merge([live], into: &subagents))
        XCTAssertEqual(subagents.count, 1)
        XCTAssertNotNil(subagents[0].finishedAt)
        XCTAssertFalse(AgentSubagent.merge([live], into: &subagents), "nothing new the second time")
    }

    // MARK: - Project labels

    func testWorktreeIsNamedAfterItsRepository() throws {
        let repo = root.appendingPathComponent("acme-app")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git/worktrees/t3-4828"), withIntermediateDirectories: true
        )
        let worktree = root.appendingPathComponent("worktrees/t3-4828")
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("apps/desktop"), withIntermediateDirectories: true
        )
        try "gitdir: \(repo.path)/.git/worktrees/t3-4828\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            AgentProjectFolder.lookUp(worktree.appendingPathComponent("apps/desktop").path),
            AgentProjectFolder.Resolved(name: "acme-app", isWorktree: true)
        )
        XCTAssertEqual(
            AgentProjectFolder.lookUp(repo.path),
            AgentProjectFolder.Resolved(name: "acme-app", isWorktree: false)
        )
    }

    func testFolderOutsideARepositoryKeepsItsName() {
        var session = AgentSession(id: "s", provider: .claude, projectName: "loose-notes", lastActivityAt: Date())
        session.workingDirectory = "/nonexistent-\(UUID().uuidString)/loose-notes"
        XCTAssertEqual(session.project, AgentProjectFolder.Resolved(name: "loose-notes", isWorktree: false))
    }

    func testCommandLabelSkipsLeadingAssignments() {
        XCTAssertEqual(
            AgentToolLabel.withoutLeadingAssignments(#"R="/Users/me/Code/my app" pnpm --dir "$R" test"#),
            #"pnpm --dir "$R" test"#
        )
        XCTAssertEqual(AgentToolLabel.withoutLeadingAssignments("A=1 B='two words'; make"), "make")
        XCTAssertEqual(AgentToolLabel.withoutLeadingAssignments("git commit -m 'x=y'"), "git commit -m 'x=y'")
        XCTAssertEqual(AgentToolLabel.withoutLeadingAssignments("X=1"), "X=1", "an assignment alone stays")
    }

    func testRunningClockKeepsItsWidth() {
        let start = Date()
        XCTAssertEqual(AgentSubagentEntry.duration(from: start, to: start.addingTimeInterval(724), padded: true), "12m 04s")
        XCTAssertEqual(AgentSubagentEntry.duration(from: start, to: start.addingTimeInterval(724), padded: false), "12m 4s")
    }
}
