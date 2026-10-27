import Darwin
import Dispatch
import Foundation
import os
import SQLite3

// Per-session view of what the user's agents are doing.
//
// The provider snapshots in AgentStatusService are one row per provider,
// inferred from file timestamps. This parses the transcripts themselves so the
// island can list concurrent sessions and open one in detail.

struct AgentActivityEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case read
        case edit
        case search
        case command
        case web
        case message
        case subagent

        var symbol: String {
            switch self {
            case .read: "doc.text"
            case .edit: "pencil"
            case .search: "magnifyingglass"
            case .command: "terminal"
            case .web: "globe"
            case .message: "text.bubble"
            case .subagent: "person.2"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    var detail: String
    /// Path or command, kept apart from the verb so the view can dim it and
    /// truncate from the head. Folded into one string, the interesting end of
    /// a long path is what gets cut.
    var target: String?
    let at: Date
    /// How many identical calls in a row this row stands for.
    var repeatCount = 1

    /// The detail panel is newest-first. Consecutive reads are one cognitive
    /// action, so collapse them into a single row without changing the stored
    /// transcript history.
    static func groupedForDisplay(_ newestFirst: [Self]) -> [Self] {
        var grouped: [Self] = []
        for entry in newestFirst {
            if entry.kind == .read, var previous = grouped.last, previous.kind == .read {
                grouped.removeLast()
                previous.detail = "Read files"
                previous.target = nil
                previous.repeatCount += entry.repeatCount
                grouped.append(previous)
            } else {
                grouped.append(entry)
            }
        }
        return grouped
    }
}

/// The project a working folder belongs to. A git worktree (T3's, Conductor's,
/// `git worktree add`) is named after its main repository, which git records
/// in the worktree's `.git` file, so every tool that makes one resolves alike.
enum AgentProjectFolder {
    struct Resolved: Equatable, Sendable {
        let name: String
        let isWorktree: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Resolved?] = [:]

    /// Nil when the folder is in no repository. Cached: a folder's repository
    /// does not change while a session runs, and rows ask on every redraw.
    static func resolve(_ directory: String) -> Resolved? {
        if let cached = lock.withLock({ cache[directory] }) { return cached }
        let resolved = lookUp(directory)
        lock.withLock {
            if cache.count > 500 { cache.removeAll() }
            cache[directory] = resolved
        }
        return resolved
    }

    static func lookUp(_ directory: String, fileManager: FileManager = .default) -> Resolved? {
        var folder = URL(fileURLWithPath: directory).standardizedFileURL
        for _ in 0 ..< 24 {
            let git = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return Resolved(name: folder.lastPathComponent, isWorktree: false)
                }
                // A worktree's `.git` is a file: `gitdir: <repo>/.git/worktrees/<name>`.
                let pointer = (try? String(contentsOf: git, encoding: .utf8)) ?? ""
                if let line = pointer.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }),
                   let marker = line.range(of: "/.git/worktrees/") {
                    let repository = line[line.index(line.startIndex, offsetBy: 7)..<marker.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    let name = URL(fileURLWithPath: repository).lastPathComponent
                    if !name.isEmpty { return Resolved(name: name, isWorktree: true) }
                }
                return Resolved(name: folder.lastPathComponent, isWorktree: false)
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }
}

/// One row of a session's Subagents section: a subagent the transcript
/// records, or one that ran as a session of its own.
struct AgentSubagentEntry: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case working, needsYou, done, failed, stopped }

    let id: String
    let name: String
    /// A model ID for session children, the role for transcript subagents.
    let model: String?
    let role: String?
    let status: Status
    let startedAt: Date?
    let endedAt: Date?
    /// Set for a subagent that is a session of its own, which can be opened.
    let sessionID: String?

    var isRunning: Bool { status == .working || status == .needsYou }

    /// Transcript subagents first, then child sessions; each oldest first.
    static func entries(for parent: AgentSession, children: [AgentSession]) -> [AgentSubagentEntry] {
        let builtIn = parent.subagents.map { agent -> AgentSubagentEntry in
            let status: Status = agent.failed ? .failed
                : agent.stopped ? .stopped
                : agent.finishedAt != nil ? .done
                : agent.isRunning(parentActive: parent.isActive) ? .working : .stopped
            return AgentSubagentEntry(
                id: agent.id.uuidString,
                name: agent.displayName,
                model: nil,
                role: agent.roleLabel,
                status: status,
                startedAt: agent.startedAt,
                endedAt: agent.finishedAt,
                sessionID: nil
            )
        }
        let sessions = children.map { child -> AgentSubagentEntry in
            let status: Status = child.needsAttention ? .needsYou
                : child.isActive ? .working
                : child.finishedAt != nil ? .done : .stopped
            return AgentSubagentEntry(
                id: child.id,
                name: child.displayName,
                model: child.model,
                role: nil,
                status: status,
                startedAt: child.startedAt ?? child.turnStartedAt,
                endedAt: status == .done ? child.finishedAt : child.lastActivityAt,
                sessionID: child.id
            )
        }
        return builtIn + sessions
    }

    /// "12m 04s" while it runs, "done 4m ago · 33m" after.
    func timeLabel(now: Date = Date()) -> String? {
        switch status {
        case .working, .needsYou:
            return startedAt.map { Self.duration(from: $0, to: now, padded: true) }
        case .done, .failed, .stopped:
            guard let endedAt else { return nil }
            let age = AgentSession.age(since: endedAt, now: now)
            let word = status == .done ? "done" : status == .failed ? "failed" : "stopped"
            let when = age == "now" ? "\(word) just now" : "\(word) \(age) ago"
            // A call that returned at once (a background launch, a refusal)
            // has no run time worth printing.
            guard let startedAt, endedAt.timeIntervalSince(startedAt) >= 1 else { return when }
            return "\(when) \u{00B7} \(Self.duration(from: startedAt, to: endedAt, padded: false))"
        }
    }

    /// "45s", "4m 12s", "1h 3m". `padded` keeps a ticking clock from jumping
    /// width as the seconds roll over.
    static func duration(from start: Date, to end: Date, padded: Bool) -> String {
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let rest = seconds % 60
            return "\(seconds / 60)m \(padded && rest < 10 ? "0" : "")\(rest)s"
        }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// A delegated subagent run.
struct AgentSubagent: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// `general-purpose`, `Explore`, and so on.
    let type: String
    let task: String
    /// The tool call that started it, so its result can mark it finished.
    var toolUseID: String? = nil
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var failed = false
    /// Claude Code's agent ID, when hooks reported the subagent.
    var agentID: String? = nil
    /// Cancelled before it finished.
    var stopped = false
    /// Launched with `run_in_background`. Its tool call returns at once; a
    /// `<task-notification>` reports when it actually ends.
    var isBackground = false

    /// A background run with no notification for this long is assumed lost
    /// (its session was killed), not still working.
    static let backgroundRunLimit: TimeInterval = 6 * 60 * 60

    /// Whether it is still working. A foreground subagent runs inside its
    /// parent's turn; a background one outlives it.
    func isRunning(parentActive: Bool, now: Date = Date()) -> Bool {
        guard finishedAt == nil, !failed, !stopped else { return false }
        if parentActive { return true }
        guard isBackground, let startedAt else { return false }
        return now.timeIntervalSince(startedAt) < Self.backgroundRunLimit
    }

    /// Marks the subagents whose tool results appear in `content` finished.
    static func complete(_ subagents: inout [AgentSubagent], from content: Any?, at: Date) {
        guard !subagents.isEmpty, let blocks = content as? [[String: Any]] else { return }
        for block in blocks where (block["type"] as? String) == "tool_result" {
            guard let id = block["tool_use_id"] as? String,
                  let index = subagents.lastIndex(where: { $0.toolUseID == id })
            else { continue }
            if resultText(block["content"]).hasPrefix("Async agent launched") {
                subagents[index].isBackground = true
                continue
            }
            subagents[index].finishedAt = at
            subagents[index].failed = (block["is_error"] as? Bool) == true
        }
    }

    /// Folds hook-reported subagents into those a transcript parse found. The
    /// same subagent is matched by its tool call or agent ID; hooks only add
    /// what the transcript has not recorded and never undo a finish.
    static func merge(_ live: [AgentHookBridge.LiveSubagent], into subagents: inout [AgentSubagent]) -> Bool {
        var changed = false
        for agent in live {
            if let index = subagents.firstIndex(where: {
                ($0.agentID != nil && $0.agentID == agent.agentID)
                    || ($0.toolUseID != nil && $0.toolUseID == agent.toolUseID)
            }) {
                var existing = subagents[index]
                existing.agentID = agent.agentID
                if existing.startedAt == nil { existing.startedAt = agent.startedAt }
                if agent.isBackground { existing.isBackground = true }
                if existing.finishedAt == nil, let finished = agent.finishedAt { existing.finishedAt = finished }
                if existing != subagents[index] {
                    subagents[index] = existing
                    changed = true
                }
            } else {
                subagents.append(AgentSubagent(
                    type: agent.type,
                    task: agent.description ?? "Delegated work",
                    toolUseID: agent.toolUseID,
                    startedAt: agent.startedAt,
                    finishedAt: agent.finishedAt,
                    agentID: agent.agentID,
                    isBackground: agent.isBackground
                ))
                changed = true
            }
        }
        return changed
    }

    /// Ends background subagents named in Claude Code's `<task-notification>`
    /// blocks: `<tool-use-id>` is the launching call, `<status>` the outcome.
    static func applyNotifications(in text: String, at: Date, to subagents: inout [AgentSubagent]) {
        guard !subagents.isEmpty, text.contains("<task-notification>") else { return }
        for block in text.components(separatedBy: "<task-notification>").dropFirst() {
            guard let id = tag("tool-use-id", in: block),
                  let index = subagents.lastIndex(where: { $0.toolUseID == id }),
                  subagents[index].finishedAt == nil
            else { continue }
            let status = tag("status", in: block)?.lowercased() ?? "completed"
            guard ["completed", "failed", "killed", "stopped", "cancelled"].contains(status) else { continue }
            subagents[index].finishedAt = at
            subagents[index].failed = status == "failed"
            subagents[index].stopped = ["killed", "stopped", "cancelled"].contains(status)
        }
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// The work-shaped name shown in Nano. Some Codex hosts encrypt the
    /// delegated brief before it reaches the transcript, leaving a Fernet-like
    /// `gAAAA...` token where a useful label should be. The task slug remains
    /// local, stable, and descriptive, so it is the safe fallback.
    var displayName: String {
        let brief = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.isOpaque(brief),
           !brief.isEmpty,
           brief.caseInsensitiveCompare("Delegated work") != .orderedSame {
            return Self.clamped(brief, limit: 72)
        }
        return Self.readableType(type) ?? "Subagent"
    }

    /// A compact role shown only when it adds information beside the name.
    var roleLabel: String? {
        guard !Self.isOpaque(task),
              let role = Self.readableType(type),
              role.caseInsensitiveCompare(displayName) != .orderedSame
        else { return nil }
        return role
    }

    private static func isOpaque(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("gAAAA") { return true }
        return trimmed.count > 80 && !trimmed.contains(where: \.isWhitespace)
    }

    private static func readableType(_ value: String) -> String? {
        let leaf = value.split(separator: "/").last.map(String.init) ?? value
        let normalized = leaf
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.caseInsensitiveCompare("agent") != .orderedSame
        else { return nil }

        switch normalized.lowercased() {
        case "general purpose": return "General"
        case "explore": return "Research"
        case "plan": return "Planning"
        default:
            let acronyms = Set(["api", "cli", "cpu", "gpu", "hud", "ui", "ux"])
            return normalized.split(whereSeparator: \.isWhitespace).map { word in
                let lower = word.lowercased()
                return acronyms.contains(lower) ? lower.uppercased() : lower.capitalized
            }.joined(separator: " ")
        }
    }

    private static func clamped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Turns a tool call into a feed row.
///
/// Shared deliberately: hook events and transcript parsing both produce these,
/// and if they formatted independently the same call would read differently
/// depending on which path happened to see it first.
enum AgentToolLabel {
    static func describe(
        tool: String,
        input: [String: Any]
    ) -> (kind: AgentActivityEntry.Kind, detail: String, target: String?) {
        let kind: AgentActivityEntry.Kind
        var verb: String
        switch tool {
        case "Read", "NotebookRead", "read", "read_file": kind = .read; verb = "Read"
        case "Edit", "MultiEdit", "NotebookEdit", "StrReplace", "apply_patch", "edit",
             "search_replace":
            kind = .edit; verb = "Edited"
        case "Write", "write": kind = .edit; verb = "Wrote"
        case "Grep", "Glob", "Search", "grep", "glob", "search", "search_tool", "list_dir":
            kind = .search; verb = "Searched"
        case "Bash", "Shell", "shell", "bash", "exec", "exec_command", "shell_command",
             "run_terminal_command":
            kind = .command; verb = "Ran"
        case "WebFetch", "WebSearch", "web_fetch", "web_search", "fetch":
            kind = .web; verb = "Fetched"
        case "TodoWrite", "update_plan", "todo": kind = .message; verb = "Updated todos"
        case "Agent", "Task", "spawn_agent", "send_message", "followup_task":
            kind = .subagent; verb = "Delegated"
        default: kind = .message; verb = tool
        }

        if ["Agent", "Task", "spawn_agent", "send_message", "followup_task"].contains(tool) {
            let described = (input["description"] as? String).map { "Delegated \($0)" } ?? verb
            let target = (input["subagent_type"] as? String)
                ?? (input["task_name"] as? String)
                ?? (input["target"] as? String)
            return (kind, described, target)
        }

        if let path = (input["file_path"] as? String)
            ?? (input["filePath"] as? String)
            ?? (input["target_file"] as? String)
            ?? (input["path"] as? String) {
            return (kind, "\(verb) \(URL(fileURLWithPath: path).lastPathComponent)", shortPath(path))
        }

        let raw = (input["command"] as? String)
            ?? (input["cmd"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["url"] as? String)
            ?? (input["query"] as? String)
            ?? ""
        guard !raw.isEmpty else { return (kind, verb, nil) }

        let summary = shellSummary(raw)
        // The terminal icon already says "ran", so a shell row is just the
        // command. Everything else keeps its verb and dims the target.
        if kind == .command {
            return (kind, truncated(summary, 72), nil)
        }
        return (kind, verb, truncated(summary, 64))
    }

    /// `.../parent/leaf.swift` - enough to disambiguate without the full path.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return path }
        return ".../" + parts.suffix(2).joined(separator: "/")
    }

    /// Strips the `cd <path> &&` preamble and heredoc payloads.
    static func shellSummary(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)

        while text.hasPrefix("cd ") {
            guard let range = text.range(of: "&&") else { break }
            text = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = withoutLeadingAssignments(text)

        if let marker = text.range(of: "<<") {
            let head = text[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let binary = head.split(separator: " ").first.map(String.init) ?? head
            return "\(binary) (script)"
        }

        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count >= 2 {
            let binary = URL(fileURLWithPath: String(words[0])).lastPathComponent
            if ["python", "python3"].contains(binary), words[1] == "-c" {
                return "\(binary) (script)"
            }
        }

        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline])
        }
        return text
    }

    /// Drops `NAME=value` prefixes (`R="/a long/path" cmd`, `X=1; cmd`), which
    /// say nothing about what runs and can fill the whole label.
    static func withoutLeadingAssignments(_ command: String) -> String {
        var rest = Substring(command)
        while let equals = rest.firstIndex(of: "="),
              rest[..<equals].range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
            var index = rest.index(after: equals)
            var quote: Character?
            while index < rest.endIndex {
                let character = rest[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character.isWhitespace || character == ";" {
                    break
                }
                index = rest.index(after: index)
            }
            guard quote == nil else { return command }
            rest = rest[index...].drop { $0.isWhitespace || $0 == ";" }
            if rest.hasPrefix("&&") { rest = rest.dropFirst(2).drop(while: \.isWhitespace) }
            if rest.isEmpty { return command }
        }
        return String(rest)
    }

    static func truncated(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "\u{2026}"
    }
}

/// A name for a session, and where it came from.
///
/// Ranked, because the sources arrive in no fixed order and the weaker ones are
/// the ones that keep arriving: a scan that reads an `ai-title` seconds after
/// the user renamed the session must not undo the rename.
/// One exchange in a session: what was asked, how much the agent did about
/// it, and the last thing it said.
struct AgentConversationTurn: Equatable, Sendable {
    var prompt: String?
    var reply: String?
    /// The newest reply as the agent wrote it, for copying. Older turns only
    /// keep the excerpt.
    var fullReply: String?
    var tools: [AgentActivityEntry.Kind: Int] = [:]

    /// Turns kept per session. The detail view is a place to catch up, not a
    /// transcript reader.
    static let limit = 6

    /// "Edited 2 files, read 4, ran 3 commands", or nil when no tool ran.
    var toolSummary: String? {
        var parts: [String] = []
        if let n = tools[.edit] { parts.append("edited \(n) \(n == 1 ? "file" : "files")") }
        if let n = tools[.read] { parts.append("read \(n)") }
        if let n = tools[.command] { parts.append("ran \(n) \(n == 1 ? "command" : "commands")") }
        if let n = tools[.search] { parts.append("searched \(n) \(n == 1 ? "time" : "times")") }
        if let n = tools[.web] { parts.append("browsed \(n)") }
        if let n = tools[.subagent] { parts.append("delegated \(n)") }
        guard !parts.isEmpty else { return nil }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    static func note(prompt: String, in turns: inout [AgentConversationTurn]) {
        // Codex records one prompt twice, as an event and as a response item.
        if let last = turns.last, last.prompt == prompt, last.reply == nil, last.tools.isEmpty {
            return
        }
        turns.append(AgentConversationTurn(prompt: prompt))
    }

    static func note(reply: String, in turns: inout [AgentConversationTurn]) {
        if turns.isEmpty { turns.append(AgentConversationTurn()) }
        turns[turns.count - 1].reply = reply
    }

    static func note(tool kind: AgentActivityEntry.Kind, in turns: inout [AgentConversationTurn]) {
        if turns.isEmpty { turns.append(AgentConversationTurn()) }
        turns[turns.count - 1].tools[kind, default: 0] += 1
    }

    /// Parsers collect raw text; only the turns that are kept get cleaned.
    static func finalized(_ turns: [AgentConversationTurn]) -> [AgentConversationTurn] {
        let kept = turns.suffix(limit)
        return kept.enumerated().compactMap { index, turn in
            var cleaned = turn
            cleaned.prompt = turn.prompt.flatMap { AgentSessionPromptSummary.body($0) }
            cleaned.reply = turn.reply.flatMap { AgentSessionPromptSummary.agentExcerpt($0, limit: 700) }
            cleaned.fullReply = index == kept.count - 1 ? turn.reply.map { String($0.prefix(8000)) } : nil
            guard cleaned.prompt != nil || cleaned.reply != nil || !cleaned.tools.isEmpty else {
                return nil
            }
            return cleaned
        }
    }
}

/// A file the session edited, with the lines its edits put in and took out.
struct AgentFileChange: Equatable, Sendable {
    let path: String
    var added = 0
    var removed = 0

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Folds `changes` into `existing`, most recently touched last.
    static func merging(_ changes: [AgentFileChange], into existing: inout [AgentFileChange]) {
        for change in changes {
            var total = change
            if let index = existing.firstIndex(where: { $0.path == change.path }) {
                total.added += existing[index].added
                total.removed += existing[index].removed
                existing.remove(at: index)
            }
            existing.append(total)
        }
    }

    /// A tail read and a full read of one transcript describe the same edits,
    /// so the larger count per file is the complete one.
    static func union(_ lhs: [AgentFileChange], _ rhs: [AgentFileChange]) -> [AgentFileChange] {
        var merged = lhs
        for change in rhs {
            if let index = merged.firstIndex(where: { $0.path == change.path }) {
                merged[index].added = max(merged[index].added, change.added)
                merged[index].removed = max(merged[index].removed, change.removed)
            } else {
                merged.append(change)
            }
        }
        return merged
    }
}

struct AgentSessionTitle: Equatable, Sendable {
    enum Source: Int, Comparable, Sendable {
        /// The agent's own wording about its work — a todo it wrote, the first
        /// line of a plan, the description it handed a subagent.
        case agentPhrase
        /// The `ai-title` record an agent writes for itself.
        case aiTitle
        /// A title the user's client keeps for the session.
        case client
        /// Typed by a person, here or in their client.
        case userNamed

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let text: String
    let source: Source
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String
    var provider: AgentProviderID
    var projectName: String
    /// A real title for the session, when any source has one.
    var title: AgentSessionTitle?
    /// What this session has been working on, from its own tool calls — the
    /// file it has edited most, weighted towards edits and towards now.
    ///
    /// This carries the everyday case. Sessions launched from a GUI client
    /// never get an `ai-title`, and the name their client derives
    /// (`north-star-a0`) says nothing the project name did not; the file the
    /// session is living in tells you which window is which.
    var focusLabel: String?
    /// Weighted basenames behind `focusLabel`, kept so the store can hold a
    /// label steady instead of swapping it whenever two files trade places.
    var focusScores: [String: Double] = [:]
    var workingDirectory: String?
    /// The app that owns this session when a client supplied that provenance.
    /// Provider and host are independent: Grok can run inside T3 Code.
    var host: AgentSessionJump.Host? = nil
    /// The launching app's bundle ID when hooks reported one. Names the app
    /// for `.app` hosts, which have no dedicated jump route.
    var hostBundleID: String? = nil

    /// What to call this session on screen.
    ///
    /// Provider/client titles win. When a CLI has not produced one yet, the
    /// user's meaningful prompt is still a better identity than the checkout
    /// folder shared by every concurrent session in that project.
    var displayName: String {
        if let text = title?.text, !text.isEmpty { return text }
        if let lastUserPrompt, !lastUserPrompt.isEmpty { return lastUserPrompt }
        if let focusLabel, !focusLabel.isEmpty { return focusLabel }
        return "Session"
    }

    /// The project to show: the repository the working folder belongs to
    /// (a worktree counts as its main repository), else the folder name.
    /// Nil when that is only a generic folder such as the home directory.
    var project: AgentProjectFolder.Resolved? {
        if let directory = workingDirectory,
           let resolved = AgentProjectFolder.resolve(directory),
           Self.projectLabel(named: resolved.name, directory: nil) != nil {
            return resolved
        }
        guard let label = Self.projectLabel(named: projectName, directory: workingDirectory) else { return nil }
        return AgentProjectFolder.Resolved(name: label, isWorktree: false)
    }

    /// Folder label for a checkout, or nil when the path is just the home
    /// directory or another generic user folder.
    static func projectLabel(named name: String? = nil, directory: String?) -> String? {
        if let directory {
            let url = URL(fileURLWithPath: directory).standardizedFileURL
            if isGenericDirectory(url) { return nil }
            let leaf = url.lastPathComponent
            return isGenericProjectLabel(leaf) ? nil : leaf
        }
        guard let name, !name.isEmpty else { return nil }
        return isGenericProjectLabel(name) ? nil : name
    }

    private static let genericHomeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music",
        "Pictures", "Library", "Applications", "Public", "Sites",
    ]

    private static func isGenericDirectory(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if url.path == home.path || url.path == "/" { return true }
        if url.deletingLastPathComponent().path == home.path,
           genericHomeFolders.contains(url.lastPathComponent) {
            return true
        }
        return false
    }

    private static func isGenericProjectLabel(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if genericHomeFolders.contains(trimmed) { return true }
        if trimmed.caseInsensitiveCompare("Session") == .orderedSame { return true }
        if trimmed.caseInsensitiveCompare(NSUserName()) == .orderedSame { return true }
        if let first = NSFullUserName().split(separator: " ").first,
           trimmed.caseInsensitiveCompare(String(first)) == .orderedSame {
            return true
        }
        return false
    }

    /// Enough signal to paint a row. ACP clients leave empty `meta.json`
    /// shells (often `cwd: $HOME`) that would otherwise show up as "Session".
    var hasVisibleWork: Bool {
        if isActive { return true }
        if title != nil { return true }
        if focusLabel != nil { return true }
        if !recentActivity.isEmpty { return true }
        if let lastUserPrompt, !lastUserPrompt.isEmpty { return true }
        return false
    }

    /// A stable lifecycle label for the compact session list. Tool activity is
    /// useful while work is live, but a finished row needs to say why it is
    /// still present instead of looking like a stuck background task.
    /// The four states every surface names the same way.
    enum Phase: Int, Comparable, Sendable {
        case needsYou, working, done, idle

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var phase: Phase {
        if needsAttention { return .needsYou }
        if isActive { return .working }
        if finishedAt != nil { return .done }
        return .idle
    }

    /// "Needs you", "Working", "Done 4m ago", "Idle".
    func statusWord(now: Date = Date()) -> String {
        switch phase {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .done:
            // ACP stubs mark "finished" as the distant past; the last write is
            // the honest age for those.
            let finished = finishedAt.map { $0 > .distantPast.addingTimeInterval(1) ? $0 : lastActivityAt } ?? lastActivityAt
            let age = Self.age(since: finished, now: now)
            return age == "now" ? "Done just now" : "Done \(age) ago"
        case .idle: return "Idle"
        }
    }

    /// What goes after the status word: the current activity while it works
    /// or waits, how long it has been quiet when idle.
    func statusDetail(now: Date = Date()) -> String? {
        switch phase {
        case .needsYou: return currentActivity ?? "waiting for your answer"
        case .working: return currentActivity
        case .done: return nil
        case .idle:
            let age = Self.age(since: lastActivityAt, now: now)
            return age == "now" ? nil : age
        }
    }

    /// Compact age: "now", "4m", "2h", "3d".
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// Needs you, then Working, then Done, then Idle; newest first in each.
    static func byPhase(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
        return lhs.lastActivityAt > rhs.lastActivityAt
    }

    /// How long the turn has run while working, or took once done: "45s",
    /// "4m 12s", "1h 3m". Nil when the turn's start is unknown or it is idle.
    func turnRuntime(now: Date = Date()) -> String? {
        guard let start = turnStartedAt else { return nil }
        let end: Date
        switch phase {
        case .working, .needsYou: end = now
        case .done:
            guard let finished = finishedAt, finished > start else { return nil }
            end = finished
        case .idle: return nil
        }
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// The context ring turns from neutral to a warning at this fullness.
    static let contextWarningFraction = 0.8

    /// Takes a title only from a source at least as strong as the one already
    /// held, so ordering between scans cannot demote a name.
    mutating func offer(_ text: String?, from source: AgentSessionTitle.Source) {
        guard let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return }
        if let title, title.source > source { return }
        title = AgentSessionTitle(text: candidate, source: source)
    }
    var lastUserPrompt: String?
    /// The agent's latest reply to the user, trimmed to a short excerpt. What
    /// people actually want to read when they open a session.
    var lastAgentMessage: String?
    var currentActivity: String?
    var model: String?
    var gitBranch: String?
    var startedAt: Date?
    /// When the current or last turn began, from the last real prompt.
    var turnStartedAt: Date?
    var lastActivityAt: Date
    /// A provider-authored completion marker. File modification time alone
    /// cannot distinguish a finished turn from a live one that is quiet.
    var finishedAt: Date?
    var contextWindow: Int?
    var contextUsed: Int?
    /// Provider-authored percentage when it is more precise than token-event
    /// reconstruction. Cursor writes this directly in its conversation header.
    var contextFractionOverride: Double?
    /// Whether the provider's own UI currently presents this conversation.
    /// Nil means that provider has no authoritative open-session index.
    var isOpenInClient: Bool?
    var recentActivity: [AgentActivityEntry] = []
    var todos: [(title: String, done: Bool)] = []
    /// Markdown from the agent's last `ExitPlanMode`, when it made a plan.
    var plan: String?
    /// Counted from Edit/Write inputs, so a changed line reads as one of each,
    /// the same way a diff would. These are attempted edits, not commits.
    var linesAdded = 0
    var linesRemoved = 0
    /// Per-file share of the counts above, most recently touched last. Empty
    /// for providers whose edits do not name a file and its text.
    var changedFiles: [AgentFileChange] = []
    /// The last few exchanges, oldest first. Empty for providers Nano only
    /// knows through hooks; `displayedTurns` covers those.
    var conversation: [AgentConversationTurn] = []
    var subagents: [AgentSubagent] = []
    /// The session that delegated this one, when it is a subagent that runs
    /// as a session of its own.
    var parentSessionID: String?
    /// Filled in by the store for the list only: the parent's name on a child
    /// that surfaced because it needs the user, and how many subagents this
    /// session has (child sessions and built-in ones) and how many still work.
    var parentTitle: String?
    var subagentsWorking = 0
    var subagentCount = 0
    var needsAttention = false
    var isActive = false
    /// The last permission answer sent from the island for this session.
    var nanoDecision: AgentHookBridge.DecisionNote?
    /// How long the row keeps saying so.
    static let decisionNoteLifetime: TimeInterval = 30

    /// What the detail view shows as the conversation.
    ///
    /// Hooks report a new prompt or reply before the transcript scan catches
    /// up, and some providers never yield parsed turns at all. Either way the
    /// latest prompt and reply are the truth about the newest exchange.
    var displayedTurns: [AgentConversationTurn] {
        var turns = conversation
        if let latest = lastUserPrompt, !latest.isEmpty {
            // `lastUserPrompt` is the first line, possibly cut with an ellipsis.
            let stem = latest.replacingOccurrences(of: "\u{2026}", with: "")
            if turns.last?.prompt?.hasPrefix(stem) != true {
                turns.append(AgentConversationTurn(prompt: latest, reply: lastAgentMessage))
            }
        }
        if turns.isEmpty, let lastAgentMessage {
            turns.append(AgentConversationTurn(reply: lastAgentMessage))
        }
        return turns
    }

    /// Fraction of the model's context window consumed, when both are known.
    var contextFraction: Double? {
        if let contextFractionOverride {
            return min(max(contextFractionOverride, 0), 1)
        }
        guard let contextWindow, contextWindow > 0, let contextUsed else { return nil }
        return min(Double(contextUsed) / Double(contextWindow), 1)
    }

    /// Model families whose clients do not write their context limit beside
    /// every request. Keep this shared because some model identities arrive
    /// after transcript parsing (notably Cursor's dashboard usage feed).
    static func inferredContextWindow(for model: String?) -> Int? {
        guard let model else { return nil }
        let slug = model.lowercased()
        if slug.contains("grok-4.6") { return 500_000 }
        if slug.contains("haiku") { return 200_000 }
        if slug.contains("opus") || slug.contains("sonnet") || slug.contains("fable") {
            return 1_000_000
        }
        if slug.contains("grok") { return 256_000 }
        return nil
    }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.lastActivityAt == rhs.lastActivityAt
            && lhs.currentActivity == rhs.currentActivity
            && lhs.lastAgentMessage == rhs.lastAgentMessage
            && lhs.needsAttention == rhs.needsAttention
            && lhs.nanoDecision == rhs.nanoDecision
            && lhs.contextUsed == rhs.contextUsed
            && lhs.contextWindow == rhs.contextWindow
            && lhs.contextFractionOverride == rhs.contextFractionOverride
            && lhs.isOpenInClient == rhs.isOpenInClient
            && lhs.host == rhs.host
            && lhs.model == rhs.model
            && lhs.finishedAt == rhs.finishedAt
            && lhs.parentSessionID == rhs.parentSessionID
            && lhs.parentTitle == rhs.parentTitle
            && lhs.subagentsWorking == rhs.subagentsWorking
            && lhs.subagentCount == rhs.subagentCount
    }
}

enum AgentSessionFilesystemChange: Sendable {
    case directory(URL)
    case file(URL)
}

/// A bounded metadata probe. No transcript contents are read on an unchanged tick.
struct AgentSessionFilesystemSnapshot: Sendable {
    struct Stamp: Equatable, Sendable {
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let size: Int64
        let inode: UInt64
    }

    struct Entry: Sendable {
        let url: URL
        let directory: Bool
        let stamp: Stamp?
    }

    let entries: [String: Entry]

    static func capture(directories: [URL], files: [URL]) -> Self {
        var entries: [String: Entry] = [:]
        for (urls, directory) in [(directories, true), (files, false)] {
            for url in urls {
                let path = url.path
                var info = stat()
                let stamp = stat(path, &info) == 0 ? Stamp(
                    modifiedSeconds: info.st_mtimespec.tv_sec,
                    modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                    size: info.st_size,
                    inode: info.st_ino
                ) : nil
                entries[path] = Entry(url: url, directory: directory, stamp: stamp)
            }
        }
        return Self(entries: entries)
    }

    func changes(since previous: Self) -> [AgentSessionFilesystemChange] {
        entries.keys.sorted().compactMap { path in
            guard let entry = entries[path], entry.stamp != previous.entries[path]?.stamp else { return nil }
            return entry.directory ? .directory(entry.url) : .file(entry.url)
        }
    }
}

/// Vnode sources sleep in the kernel until a watched path changes. Directories
/// discover new transcripts; files make already-known sessions update without
/// waiting for a recovery scan.
@MainActor
final class AgentSessionFilesystemMonitor {
    private var directorySources: [String: DispatchSourceFileSystemObject] = [:]
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private let didChange: (AgentSessionFilesystemChange) -> Void
    var didReconcile: ((AgentSessionFilesystemChange) -> Void)?
    private var directories: [URL] = []
    private var files: [URL] = []
    private var previousSnapshot: AgentSessionFilesystemSnapshot?
    private var generation = 0
    private var isReconciling = false
    /// Standardizing a URL touches the filesystem. Reconciliation asks for
    /// the same few hundred paths every five seconds on the main actor.
    private var standardizedPaths: [URL: String] = [:]

    private func key(for url: URL) -> String {
        if let known = standardizedPaths[url] { return known }
        let path = url.standardizedFileURL.path
        standardizedPaths[url] = path
        return path
    }

    init(didChange: @escaping (AgentSessionFilesystemChange) -> Void) {
        self.didChange = didChange
    }

    func update(directories: [URL], files: [URL]) {
        self.directories = directories
        self.files = files
        generation += 1
        updateSources(
            &directorySources,
            urls: directories,
            eventMask: [.write, .attrib, .delete, .rename],
            change: { .directory($0) }
        )
        updateSources(
            &fileSources,
            urls: files,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            change: { .file($0) }
        )
    }

    func stop() {
        generation += 1
        directories = []
        files = []
        previousSnapshot = nil
        directorySources.values.forEach { $0.cancel() }
        fileSources.values.forEach { $0.cancel() }
        directorySources.removeAll()
        fileSources.removeAll()
        standardizedPaths.removeAll()
    }

    func reconcile(additionalDirectories: [URL] = []) async {
        guard !isReconciling, !directories.isEmpty else { return }
        isReconciling = true
        defer { isReconciling = false }
        let generation = generation
        let directories = directories + additionalDirectories
        let files = files
        let snapshot = await Task.detached(priority: .utility) {
            AgentSessionFilesystemSnapshot.capture(directories: directories, files: files)
        }.value
        guard generation == self.generation else { return }
        let changes = previousSnapshot.map { snapshot.changes(since: $0) }
            // Close the startup gap between the discovery scan and attaching watches.
            ?? [.directory(directories[0])]
        previousSnapshot = snapshot
        let emit = didReconcile ?? didChange
        if let directory = changes.first(where: { if case .directory = $0 { return true }; return false }) {
            emit(directory)
        } else {
            changes.forEach(emit)
        }
        // Retry failed opens and replace watches whose inode disappeared.
        for change in changes {
            switch change {
            case .directory(let url):
                directorySources.removeValue(forKey: key(for: url))?.cancel()
            case .file(let url):
                fileSources.removeValue(forKey: key(for: url))?.cancel()
            }
        }
        update(directories: self.directories, files: files)
    }

    private func updateSources(
        _ sources: inout [String: DispatchSourceFileSystemObject],
        urls: [URL],
        eventMask: DispatchSource.FileSystemEvent,
        change: @escaping (URL) -> AgentSessionFilesystemChange
    ) {
        var wanted: [String: URL] = [:]
        for url in urls { wanted[key(for: url)] = url }
        for path in sources.keys where wanted[path] == nil {
            sources.removeValue(forKey: path)?.cancel()
        }
        for (path, url) in wanted where sources[path] == nil {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: eventMask,
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.didChange(change(url)) }
            source.setCancelHandler { close(descriptor) }
            sources[path] = source
            source.resume()
        }
    }
}

fileprivate struct AgentSessionParseResult: Sendable {
    let sessions: [AgentSession]
    let monitoredFiles: [URL]
    let monitoredFileProviders: [String: AgentProviderID]
    let knownTitles: AgentKnownTitles
}

fileprivate struct AgentSessionIncrementalParseResult: Sendable {
    let sessions: [AgentSession]
    let knownTitles: AgentKnownTitles
    let refreshedKnownTitles: Bool
}

enum AgentSessionRefreshCadence {
    static let discoveryDelay: TimeInterval = 0.15
    static let fileTrailingDelay: TimeInterval = 0.45
    static let fileMaximumDelay: TimeInterval = 1.5

    /// While the island is collapsed it shows counts and status, which hooks
    /// already deliver live. Transcript writes then refresh at most this often
    /// instead of within 1.5s of every write.
    static let unobservedFileInterval: TimeInterval = 10

    static func fileDelay(burstStartedAt: Date, now: Date) -> TimeInterval {
        min(fileTrailingDelay, max(0, fileMaximumDelay - now.timeIntervalSince(burstStartedAt)))
    }
}

@MainActor
final class AgentSessionStore: ObservableObject {
    /// Most recent activity first.
    @Published private(set) var sessions: [AgentSession] = []

    /// Whether the island is expanded. Set by `IslandViewModel`; drives how
    /// eagerly transcript writes are re-parsed.
    var isObserved = false {
        didSet {
            guard isObserved, !oldValue, refreshDebounceTask != nil,
                  case .files = debouncedRefreshReason
            else { return }
            // Opening the island flushes a throttled refresh immediately.
            refreshDebounceTask?.cancel()
            refreshDebounceTask = Task { [weak self] in
                guard let self else { return }
                refreshDebounceTask = nil
                refreshBurstStartedAt = nil
                let reason = debouncedRefreshReason ?? .manual
                debouncedRefreshReason = nil
                await performRefresh(reason: reason)
            }
        }
    }
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    /// A session with no writes for this long is no longer "working".
    private static let activeWindow: TimeInterval = 120
    private static let sessionLimit = 20

    /// Watchers are the normal update path. This deliberately slow scan only
    /// heals missed vnode events, replaced files, and paths created while the
    /// machine was asleep.
    nonisolated static let integrityScanInterval: TimeInterval = 12 * 60
    nonisolated static let reconciliationInterval: TimeInterval = 5

    /// Directory/integrity discoveries also refresh the compact provider row.
    /// File writes already have a cheaper provider-level watcher of their own.
    var discoveryDidChange: ((_ isIntegrityScan: Bool) -> Void)?

    /// A transcript watcher observed a live session cross a provider-authored
    /// terminal boundary. This is the fallback completion path for providers
    /// whose optional hooks are unavailable or have not been trusted yet.
    var didFinishSession: ((AgentSession) -> Void)?

    private enum RefreshReason {
        case startup
        case directory
        case files([String: AgentProviderID])
        case integrity
        case manual

        var rebuildsDirectories: Bool {
            switch self {
            case .startup, .directory, .integrity: true
            case .files, .manual: false
            }
        }

    }

    private var filesystemMonitor: AgentSessionFilesystemMonitor?
    private var monitoredDirectories: [URL] = []
    private var integrityTimer: Timer?
    private var reconciliationTimer: Timer?
    private var refreshDebounceTask: Task<Void, Never>?
    private var refreshBurstStartedAt: Date?
    private var debouncedRefreshReason: RefreshReason?
    private var monitorGeneration = 0
    private var monitoredFileProviders: [String: AgentProviderID] = [:]
    private var latestHookStates: [String: AgentHookBridge.LiveSessionState] = [:]
    private var pendingRefreshReason: RefreshReason?
    private var parserKnownTitles: AgentKnownTitles?
    private var parserKnownTitlesReadAt = Date.distantPast

    /// Review deadlines are intentionally launch-local: they extend a finished
    /// row past `lingerWindow` only when Nano saw the completion happen, so
    /// long-settled work does not come back as actionable on every launch.
    private var completionReviewDeadlines: [String: Date] = [:]

    /// How long a finished session stays on the island after its last write.
    ///
    /// The island has no separate history list, so this *is* the session list.
    /// Three minutes was long enough to read a result and short enough that a
    /// finished row vanished while the user was still in the same sitting.
    nonisolated static let lingerWindow: TimeInterval = 15 * 60

    /// An explicit provider completion remains actionable long enough to open
    /// its review, but only when Nano observed it during this launch.
    static let completionLingerWindow: TimeInterval = 2 * 60

    /// Rows the island actually paints. Live sessions beyond this stay in
    /// memory and come back to the top as soon as they write again.
    static let islandVisibleLimit = 8

    /// Which session's detail is open, if any.
    ///
    /// Held here rather than as view state because the island sizes itself to
    /// its content, and the detail view is much taller than a list row — the
    /// window needs to know which one is on screen.
    @Published var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            // A stale height from the previous session would size the window
            // wrong for one frame on the way in.
            detailContentHeight = 0
            guard let selectedID else { return }
            loadFullHistory(for: selectedID)
        }
    }

    /// Natural height of the open session's detail content, reported by the
    /// view. The island sizes itself from this, so collapsing a section or
    /// opening a session with less to show shrinks the window to match.
    @Published var detailContentHeight: CGFloat = 0
    /// Measured height of the usage breakdown, so the island fits it.
    @Published var usageContentHeight: CGFloat = 0

    /// Natural height of the session list, same arrangement as the detail view.
    @Published var listContentHeight: CGFloat = 0

    /// Sessions already re-read in full, so reopening one does not re-scan.
    private var fullyLoaded: Set<String> = []

    /// Every title seen this run, not just the last scan's.
    ///
    /// Two reasons to accumulate rather than replace: a session hooks report
    /// before the next scan still comes up named, and a session that has since
    /// exited keeps the title it had while it ran — the client deletes its
    /// record with the process, and a finished row renaming itself back to its
    /// folder while the user is still reading it is worse than a stale name.
    private var knownTitles: [String: AgentSessionTitle] = [:]

    /// Names typed here, by session ID. Outrank every other source.
    private var localNames: [String: String] = AgentSessionRenames.load()

    /// Rows the user cleared from the island, by session ID, with the moment
    /// each was cleared. A row stays hidden only until it is active again.
    @Published private var dismissals: [String: Date]
    private let dismissalsURL: URL?

    /// Cursor can emit a hook before its transcript is discovered. Keep its
    /// native header index beside the hook path so that first row is named and
    /// scoped correctly without waiting for a potentially expensive scan.
    private var cursorMetadata: [String: AgentCursorConversationMetadata.Entry]

    /// Hook traffic can be several events per second. T3's SQLite state is
    /// authoritative, but reopening and walking it for every tool event would
    /// move that work onto the UI actor. Cache it briefly; lifecycle changes
    /// still settle within the same couple of seconds as the island animation.
    private var t3RuntimeCache = AgentT3RuntimeIndex()
    private var t3RuntimeCacheReadAt = Date.distantPast

    /// Devin hooks report no title, model, or cwd, so its session store fills
    /// those in. Same caching argument as the T3 index above.
    private var devinMetadata: [String: AgentDevinSessionMetadata.Entry] = [:]
    private var devinMetadataReadAt = Date.distantPast

    private func currentDevinMetadata(at now: Date = Date()) -> [String: AgentDevinSessionMetadata.Entry] {
        if now.timeIntervalSince(devinMetadataReadAt) >= 5 {
            devinMetadata = AgentDevinSessionMetadata.index()
            devinMetadataReadAt = now
        }
        return devinMetadata
    }

    /// The file label currently on screen for each session — see
    /// `focusLabel(for:)` for why it is held rather than recomputed.
    private var focusLabels: [String: String] = [:]

    /// Child-to-parent links for subagents that run as sessions of their own.
    private let subagentLinks: AgentSubagentLinks

    init(
        cursorMetadata: [String: AgentCursorConversationMetadata.Entry]? = nil,
        dismissalsURL: URL? = AgentSessionDismissals.defaultURL,
        subagentLinks: AgentSubagentLinks = .shared
    ) {
        self.cursorMetadata = cursorMetadata ?? [:]
        self.dismissalsURL = dismissalsURL
        self.subagentLinks = subagentLinks
        dismissals = AgentSessionDismissals.load(from: dismissalsURL)
        if let cursorMetadata {
            parserKnownTitles = AgentKnownTitles(cursor: cursorMetadata)
            parserKnownTitlesReadAt = Date()
        }
    }

    /// The session whose name is being edited in place, if any.
    @Published var renamingID: String?

    /// Re-reads the whole transcript for the open session, off the main actor,
    /// then merges only the cumulative fields. Everything else stays as the
    /// cheap tail scan left it, so a slow read cannot blank the view.
    private func loadFullHistory(for id: String) {
        guard !fullyLoaded.contains(id) else { return }
        fullyLoaded.insert(id)

        Task { [weak self] in
            let full = await Task.detached(priority: .userInitiated) {
                AgentSessionParsers.parseFull(sessionID: id)
            }.value

            guard let self else { return }
            guard let full else {
                // A transient read failure or a transcript over the current
                // ceiling must remain retryable the next time the user opens
                // the session.
                fullyLoaded.remove(id)
                return
            }
            guard let index = sessions.firstIndex(where: { $0.id == id }) else {
                fullyLoaded.remove(id)
                return
            }

            // The detail view's feed comes from here too, so opening a session
            // always shows its real history rather than whatever fitted in the
            // list scan's window.
            // Assign the completed value once. Mutating fields through an
            // @Published array subscript does not reliably notify SwiftUI, so
            // the parser could find subagents while the open detail stayed
            // frozen on the cheap tail-scan result.
            var updated = sessions[index]
            if !full.recentActivity.isEmpty {
                updated.recentActivity = full.recentActivity
            }
            updated.linesAdded = full.linesAdded
            updated.linesRemoved = full.linesRemoved
            updated.changedFiles = full.changedFiles
            if !full.conversation.isEmpty { updated.conversation = full.conversation }
            updated.subagents = full.subagents
            if !full.todos.isEmpty { updated.todos = full.todos }
            if let plan = full.plan { updated.plan = plan }
            if let prompt = full.lastUserPrompt { updated.lastUserPrompt = prompt }
            if let model = full.model {
                updated.model = model
            } else if updated.model == nil {
                updated.model = CursorConversationModels.model(for: id)
            }
            if let started = full.startedAt { updated.startedAt = started }
            if let branch = full.gitBranch { updated.gitBranch = branch }
            if let activity = full.currentActivity { updated.currentActivity = activity }
            if !full.focusScores.isEmpty {
                updated.focusScores = full.focusScores
                updated.focusLabel = focusLabel(for: updated)
            }
            sessions[index] = updated
        }
    }

    var selectedSession: AgentSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    /// Providers the user enabled in Settings. `nil` means unfiltered, which
    /// is what tests and stores created before Settings answered see. IslandState
    /// sets it next to the hook bridge's own provider gate.
    var enabledProviders: Set<AgentProviderID>?

    /// Providers whose rows Nano discovers from on-disk stores rather than
    /// hooks. They vanish when the provider's Settings toggle is off; every
    /// other provider's rows come from hooks or transcripts and stay.
    nonisolated static let diskDiscoveredProviders: Set<AgentProviderID> = [
        .devin, .cline, .qwen, .kilo, .goose,
    ]

    /// What the island shows: working now, or recently enough to still matter.
    /// Everything else is history and belongs in the full list, not the island.
    var liveSessions: [AgentSession] {
        liveSessions(at: Date())
    }

    func liveSessions(at now: Date) -> [AgentSession] {
        recentSessions(at: now).filter { !isDismissed($0) }.sorted(by: AgentSession.byPhase)
    }

    /// Rows that would be on the island had the user not cleared them.
    var dismissedSessionCount: Int {
        recentSessions(at: Date()).filter(isDismissed).count
    }

    /// Clears a row off the island until its next activity. A row waiting on
    /// the user cannot be cleared: a hidden approval is a trap. `isActive` is
    /// not a reason to refuse, since it lingers two minutes past the last
    /// write and "just finished" is exactly when a row gets cleared.
    func dismiss(_ id: String, now: Date = Date()) {
        guard let session = sessions.first(where: { $0.id == id }),
              !session.needsAttention
        else { return }
        // Stamped with the later of the two so a write already on disk but not
        // yet parsed does not bring the row back a second after it was cleared.
        dismissals[id] = max(session.lastActivityAt, now)
        if selectedID == id { selectedID = nil }
        AgentSessionDismissals.save(dismissals, to: dismissalsURL)
    }

    func restoreDismissedSessions() {
        dismissals.removeAll()
        AgentSessionDismissals.save(dismissals, to: dismissalsURL)
    }

    /// T3 names each thread by running a one-shot agent with this prompt. It
    /// is the host's own chore, not a session the user started or can open.
    nonisolated static func isHostHousekeeping(_ session: AgentSession) -> Bool {
        if session.lastUserPrompt.map(isHostHousekeepingPrompt) == true { return true }
        return session.title.map { isHostHousekeepingPrompt($0.text) } == true
            || isHostHousekeepingPrompt(session.displayName)
    }

    nonisolated static func isHostHousekeepingPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Generate a title that will help the user recognize this T3 Code thread")
    }

    private func isDismissed(_ session: AgentSession) -> Bool {
        guard let dismissedAt = dismissals[session.id] else { return false }
        return session.lastActivityAt <= dismissedAt && !session.needsAttention
    }

    // MARK: Subagent sessions

    /// The session that delegated `session`, if Nano knows it.
    func parentSession(of session: AgentSession) -> AgentSession? {
        guard let parentID = session.parentSessionID ?? subagentLinks.parent(of: session.id),
              parentID != session.id
        else { return nil }
        return sessions.first { $0.id == parentID }
    }

    /// Sessions `parentID` delegated, oldest first.
    func childSessions(of parentID: String) -> [AgentSession] {
        sessions
            .filter { ($0.parentSessionID ?? subagentLinks.parent(of: $0.id)) == parentID && $0.id != parentID }
            .sorted { ($0.startedAt ?? $0.lastActivityAt) < ($1.startedAt ?? $1.lastActivityAt) }
    }

    /// A child session folds into its parent's row. It keeps a row of its own
    /// only while it needs the user, since a hidden approval is a trap, or
    /// when its parent is not a session Nano knows.
    private func recentSessions(at now: Date) -> [AgentSession] {
        var parentIDs: [String: String] = [:]
        var children: [String: [AgentSession]] = [:]
        let known = Set(sessions.map(\.id))
        for session in sessions {
            guard let parentID = session.parentSessionID ?? subagentLinks.parent(of: session.id),
                  parentID != session.id, known.contains(parentID)
            else { continue }
            parentIDs[session.id] = parentID
            children[parentID, default: []].append(session)
        }
        let decorated = sessions.compactMap { session -> AgentSession? in
            var shown = session
            if let parentID = parentIDs[session.id] {
                guard session.needsAttention else { return nil }
                shown.parentTitle = sessions.first { $0.id == parentID }?.displayName
            }
            // Separate child sessions and the agent's own built-in subagents
            // count alike.
            let own = children[session.id] ?? []
            shown.subagentCount = own.count + session.subagents.count
            shown.subagentsWorking = own.filter { $0.isActive || $0.needsAttention }.count
                + session.subagents.filter { $0.isRunning(parentActive: session.isActive, now: now) }.count
            return shown
        }
        let cutoff = now.addingTimeInterval(-Self.lingerWindow)
        let live = decorated.filter { session in
            // A parent waiting on its subagents is still in use.
            if session.subagentsWorking > 0, !Self.isHostHousekeeping(session) { return true }
            let completionIsReviewable = completionReviewDeadlines[session.id].map { $0 >= now } == true
            let isVisible: Bool
            if let isOpenInClient = session.isOpenInClient {
                // Cursor counts every conversation that has not been archived
                // as open, including ones untouched for days. Open-in-client
                // is a reason to keep a row while it is in use, not a pass
                // around the linger window, or a chat left in Cursor's sidebar
                // stays on the island forever.
                isVisible = completionIsReviewable
                    || (isOpenInClient && (session.isActive || session.lastActivityAt > cutoff))
            } else if session.finishedAt != nil {
                // A provider-authored completion is a better "done" signal than
                // a quiet transcript, not a reason to vanish sooner. Finished
                // rows get the same linger as everything else; the review
                // deadline only extends it for a completion seen this launch.
                isVisible = completionIsReviewable || session.lastActivityAt > cutoff
            } else {
                isVisible = session.isActive || session.lastActivityAt > cutoff
            }
            return isVisible && session.hasVisibleWork && !Self.isHostHousekeeping(session)
        }

        // Only disk-discovered providers are gated here: their rows come from
        // databases Nano reads unconditionally. A hook row can carry a vendor
        // provider (OpenCode running Kimi) that the user never opted into —
        // dropping those would be a regression, so they are never filtered.
        return live.filter {
            !Self.diskDiscoveredProviders.contains($0.provider)
                || enabledProviders?.contains($0.provider) ?? true
        }
    }

    /// Starts the one launch scan, then leaves normal updates to hooks and
    /// filesystem events. Calling this again replaces the watcher generation
    /// rather than adding another timer.
    func startMonitoring() {
        stopMonitoring()
        monitorGeneration += 1
        let generation = monitorGeneration
        filesystemMonitor = AgentSessionFilesystemMonitor { [weak self] change in
            self?.scheduleFilesystemRefresh(change)
        }
        filesystemMonitor?.didReconcile = { [weak self] change in
            // Hooks from one session do not establish coverage for its peers.
            self?.scheduleFilesystemRefresh(change, ignoreHookCoverage: true)
        }

        Task { [weak self] in
            guard let self else { return }
            await performRefresh(reason: .startup)
            guard generation == monitorGeneration, filesystemMonitor != nil else { return }
            scheduleIntegrityTimer()
            scheduleReconciliationTimer()
        }
    }

    func stopMonitoring() {
        monitorGeneration += 1
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        refreshBurstStartedAt = nil
        integrityTimer?.invalidate()
        integrityTimer = nil
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        filesystemMonitor?.stop()
        filesystemMonitor = nil
        monitoredDirectories = []
        monitoredFileProviders = [:]
        debouncedRefreshReason = nil
        pendingRefreshReason = nil
    }

    func refresh() async {
        await performRefresh(reason: .manual)
    }

    private func performRefresh(reason: RefreshReason) async {
        guard !isScanning else {
            pendingRefreshReason = stronger(reason, than: pendingRefreshReason)
            return
        }
        isScanning = true

        if case .files(let changes) = reason {
            let cachedKnownTitles = Date().timeIntervalSince(parserKnownTitlesReadAt) < 5
                ? parserKnownTitles
                : nil
            let result = await Task.detached(priority: .utility) {
                AgentSessionParsers.parseIncrementalResult(
                    changes,
                    knownTitles: cachedKnownTitles
                )
            }.value
            parserKnownTitles = result.knownTitles
            cursorMetadata = result.knownTitles.cursor
            if result.refreshedKnownTitles { parserKnownTitlesReadAt = Date() }
            let refreshed = result.sessions
            if refreshed.isEmpty, !changes.isEmpty {
                // A watched file may be between rename and replacement. Heal
                // that rare case with one discovery scan instead of leaving a
                // stale row until the twelve-minute integrity pass.
                pendingRefreshReason = stronger(.directory, than: pendingRefreshReason)
            } else {
                applyIncrementalSessions(refreshed)
                lastScan = Date()
            }
            isScanning = false
            await performPendingRefreshIfNeeded()
            return
        }

        let rebuildDirectories = reason.rebuildsDirectories
        let result = await Task.detached(priority: .utility) {
            let parsed = AgentSessionParsers.parseRecentResult()
            let directories = rebuildDirectories
                ? AgentSessionParsers.filesystemMonitoringDirectories(activeFiles: parsed.monitoredFiles)
                : nil
            return (parsed, directories)
        }.value
        parserKnownTitles = result.0.knownTitles
        parserKnownTitlesReadAt = Date()
        cursorMetadata = result.0.knownTitles.cursor

        let now = Date()
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = result.0.sessions
            .map { session in
                var updated = session
                // A discovery scan is also a partial tail read. Preserve known
                // metadata even when the session has never been expanded.
                if let existing = previous[updated.id] {
                    updated = AgentSessionParsers.combine(existing, updated)
                }
                remember(updated)
                // The scan applied what it could read; this adds back titles
                // whose source has since gone away, then anything typed here.
                applyKnownTitle(to: &updated)
                updated.focusLabel = focusLabel(for: updated)
                updated.isActive = updated.finishedAt == nil
                    && now.timeIntervalSince(session.lastActivityAt) < Self.activeWindow
                return updated
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(Self.sessionLimit)
            .map { $0 }

        // A filesystem scan must not erase hook-only sessions (Gemini, Pi,
        // Kimi, and a just-started session whose transcript is not visible yet).
        applyHookState(latestHookStates)

        lastScan = now
        if let directories = result.1 { monitoredDirectories = directories }
        monitoredFileProviders = result.0.monitoredFileProviders
        filesystemMonitor?.update(
            directories: monitoredDirectories,
            files: result.0.monitoredFiles
        )
        isScanning = false

        switch reason {
        case .directory:
            discoveryDidChange?(false)
        case .integrity:
            discoveryDidChange?(true)
        default:
            break
        }
        await performPendingRefreshIfNeeded()
    }

    func applyIncrementalSessions(_ refreshed: [AgentSession], now: Date = Date()) {
        var merged = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var newlyFinished: [AgentSession] = []
        for var session in refreshed {
            if let existing = merged[session.id] {
                session = AgentSessionParsers.combine(existing, session)
                if existing.finishedAt == nil, session.finishedAt != nil {
                    completionReviewDeadlines[session.id] = now.addingTimeInterval(Self.completionLingerWindow)
                    newlyFinished.append(session)
                }
            }
            if session.finishedAt == nil {
                completionReviewDeadlines.removeValue(forKey: session.id)
            }
            remember(session)
            applyKnownTitle(to: &session)
            session.focusLabel = focusLabel(for: session)
            session.isActive = session.finishedAt == nil
                && now.timeIntervalSince(session.lastActivityAt) < Self.activeWindow
            merged[session.id] = session
        }
        sessions = merged.values
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(Self.sessionLimit)
            .map { $0 }
        applyHookState(latestHookStates, now: now)
        newlyFinished.forEach { didFinishSession?($0) }
    }

    private func performPendingRefreshIfNeeded() async {
        guard let pending = pendingRefreshReason else { return }
        pendingRefreshReason = nil
        await performRefresh(reason: pending)
    }

    private func scheduleFilesystemRefresh(
        _ change: AgentSessionFilesystemChange,
        ignoreHookCoverage: Bool = false
    ) {
        let reason: RefreshReason
        switch change {
        case .directory:
            reason = .directory
        case .file(let url):
            let provider = monitoredFileProviders[url.standardizedFileURL.path]
            if !ignoreHookCoverage, let provider,
               Self.hasRecentHookCoverage(for: provider, in: latestHookStates) {
                return
            }
            guard let provider else {
                reason = .directory
                break
            }
            reason = .files([url.standardizedFileURL.path: provider])
        }

        let existingReason = debouncedRefreshReason
        debouncedRefreshReason = stronger(reason, than: existingReason)
        if existingReason?.rebuildsDirectories == true, refreshDebounceTask != nil {
            // Once discovery is queued, high-frequency file writes must not
            // keep pushing its deadline back.
            return
        }
        let now = Date()
        let fileOnly: Bool
        if case .files = debouncedRefreshReason { fileOnly = true } else { fileOnly = false }

        // Collapsed: a throttle, not a debounce. A pending refresh keeps its
        // deadline and the new paths ride along in the merged reason.
        if fileOnly, !isObserved, refreshDebounceTask != nil {
            return
        }

        if fileOnly {
            refreshBurstStartedAt = refreshBurstStartedAt ?? now
        } else {
            refreshBurstStartedAt = nil
        }
        refreshDebounceTask?.cancel()
        let delay = fileOnly
            ? (isObserved
                ? AgentSessionRefreshCadence.fileDelay(
                    burstStartedAt: refreshBurstStartedAt ?? now,
                    now: now
                )
                : AgentSessionRefreshCadence.unobservedFileInterval)
            : AgentSessionRefreshCadence.discoveryDelay
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            refreshDebounceTask = nil
            refreshBurstStartedAt = nil
            let reason = debouncedRefreshReason ?? .manual
            debouncedRefreshReason = nil
            await performRefresh(reason: reason)
        }
    }

    /// Cursor CLI/ACP hooks are partial and often omit a usable session id, so
    /// a recent Cursor hook must not disable the file watchers that actually
    /// see `acp-sessions` and `chats` stores.
    nonisolated static func hasRecentHookCoverage(
        for provider: AgentProviderID,
        in states: [String: AgentHookBridge.LiveSessionState],
        now: Date = Date()
    ) -> Bool {
        // Cursor's hooks omit usable session ids, and the disk-discovered
        // providers emit no hooks at all for sessions that predate (or lack)
        // installation, so file/db activity is their only live signal.
        if provider == .cursor || diskDiscoveredProviders.contains(provider) { return false }
        let cutoff = now.addingTimeInterval(-120)
        return states.values.contains { state in
            guard state.lastEventAt > cutoff else { return false }
            if provider == .opencode { return state.source == "opencode" }
            return Self.provider(for: state) == provider
        }
    }

    private func scheduleIntegrityTimer() {
        integrityTimer?.invalidate()
        let timer = Timer(timeInterval: Self.integrityScanInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.performRefresh(reason: .integrity) }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        integrityTimer = timer
    }

    private func scheduleReconciliationTimer() {
        reconciliationTimer?.invalidate()
        let timer = Timer(timeInterval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !isScanning else { return }
                await filesystemMonitor?.reconcile(
                    additionalDirectories: AgentSessionParsers.recentCodexDiscoveryDirectories()
                )
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        reconciliationTimer = timer
    }

    private func stronger(
        _ proposed: RefreshReason,
        than current: RefreshReason?
    ) -> RefreshReason {
        guard let current else { return proposed }
        if proposed.rebuildsDirectories { return proposed }
        if current.rebuildsDirectories { return current }
        switch (proposed, current) {
        case (.manual, _):
            return proposed
        case (_, .manual):
            return current
        case (.files(let proposedFiles), .files(let currentFiles)):
            return .files(currentFiles.merging(proposedFiles) { _, newest in newest })
        default:
            return current
        }
    }

    // MARK: - Naming

    private func remember(_ session: AgentSession) {
        guard let title = session.title else { return }
        if let held = knownTitles[session.id], held.source > title.source { return }
        knownTitles[session.id] = title
    }

    private func applyKnownTitle(to session: inout AgentSession) {
        if session.provider == .cursor, let entry = cursorMetadata[session.id] {
            session.offer(entry.name, from: .client)
            session.contextFractionOverride = entry.contextFraction
            session.isOpenInClient = entry.isOpenInClient
            if entry.isOpenInClient {
                session.finishedAt = nil
            } else {
                // Cursor can archive the superseded half of a retry while both
                // transcript files are still fresh. Archive state is stronger
                // than recency: the hidden predecessor must not count as a
                // second active conversation.
                session.finishedAt = session.finishedAt ?? session.lastActivityAt
                session.isActive = false
            }
        }
        if session.provider == .devin,
           let entry = currentDevinMetadata()[session.id] {
            // The client's own record is the only naming a hook-only Devin
            // session has; fill gaps rather than replace what hooks saw.
            session.offer(entry.title, from: .client)
            if session.model == nil, let model = entry.model {
                session.model = model
            }
            if session.workingDirectory == nil, let directory = entry.workingDirectory {
                session.workingDirectory = directory
                if let label = AgentSession.projectLabel(directory: directory) {
                    session.projectName = label
                }
            }
        }
        if let title = knownTitles[session.id] {
            session.offer(title.text, from: title.source)
        }
        // Applied last of the two so a name typed here beats one typed in the
        // client, which is the only case where both are `userNamed`.
        session.offer(localNames[session.id], from: .userNamed)
    }

    /// Picks the file to name a session after, and then mostly keeps it.
    ///
    /// The label is recomputed from a moving tail window, so two files with
    /// near-equal scores would trade places every scan. A session's name
    /// changing while the user is reading the list is worse than naming it
    /// after the second-busiest file, so the incumbent is only displaced by a
    /// clear lead.
    private func focusLabel(for session: AgentSession) -> String? {
        let scores = session.focusScores
        guard let leader = scores.max(by: { $0.value < $1.value }) else {
            return focusLabels[session.id]
        }
        if let incumbent = focusLabels[session.id],
           let held = scores[incumbent],
           held * 1.5 >= leader.value {
            return incumbent
        }
        focusLabels[session.id] = leader.key
        return leader.key
    }

    /// Starts an in-place edit of a session's name.
    func beginRename(_ id: String) {
        // The field lives in the list row, so a rename started from the open
        // session has to come back out to the list to reach it.
        selectedID = nil
        renamingID = id
    }

    /// Commits a typed name, or clears it when the text is empty.
    func rename(_ id: String, to name: String?) {
        renamingID = nil
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmed, !trimmed.isEmpty {
            localNames[id] = trimmed
        } else {
            localNames.removeValue(forKey: id)
        }
        AgentSessionRenames.save(localNames)

        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let trimmed, !trimmed.isEmpty {
            sessions[index].offer(trimmed, from: .userNamed)
            return
        }
        // Clearing has to take the title away, and `offer` only ever raises.
        // Dropping both the held and the shown title lets the next scan put
        // back whatever the agent and client actually say.
        knownTitles.removeValue(forKey: id)
        sessions[index].title = nil
    }

    /// The name the user typed here, if any — the field starts from it, and
    /// the menu only offers to remove one that exists.
    func localName(_ id: String) -> String? {
        localNames[id]
    }

    /// Usage events name the model after the list has already been built.
    func applyCursorModels() {
        var next = sessions
        CursorConversationModels.apply(to: &next)
        let nextDetails = next.map { ($0.model, $0.contextUsed, $0.contextWindow) }
        let currentDetails = sessions.map { ($0.model, $0.contextUsed, $0.contextWindow) }
        if !zip(nextDetails, currentDetails).allSatisfy({ pair in
            pair.0.0 == pair.1.0 && pair.0.1 == pair.1.1 && pair.0.2 == pair.1.2
        }) || nextDetails.count != currentDetails.count {
            sessions = next
        }
    }

    /// Builds the session list from hook state, using parsed transcripts only
    /// for sessions hooks never mentioned.
    ///
    /// This is the inversion: previously every scan parsed up to twenty
    /// transcripts to discover what was running, and hooks merely annotated the
    /// result. Agents already push `session_id`, `cwd` and the tool they just
    /// ran, so for any agent with hooks installed that work was redundant.
    /// Parsing stays for agents without them, and for the details hooks do not
    /// carry - context size, todos, the plan - which are fetched when a session
    /// is actually opened.
    func applyHookState(
        _ states: [String: AgentHookBridge.LiveSessionState],
        now: Date = Date(),
        t3Runtime suppliedT3Runtime: AgentT3RuntimeIndex? = nil,
        refreshT3Runtime: Bool = false
    ) {
        latestHookStates = states
        guard !states.isEmpty else { return }
        var changed = false
        let shouldCheckT3 = suppliedT3Runtime != nil || states.values.contains { state in
            let provider = Self.provider(for: state)
            return provider == .cursor || provider == .grok
                || AgentProviderID.normalize(state.model) == AgentProviderID.grok.rawValue
        }
        let t3Runtime = suppliedT3Runtime
            ?? (shouldCheckT3
                ? currentT3RuntimeIndex(forceRefresh: refreshT3Runtime)
                : AgentT3RuntimeIndex())

        for (id, pushedState) in states {
            var state = pushedState
            if state.host == nil, let bundleID = state.hostBundleID {
                state.host = AgentSessionJump.host(bundleID: bundleID)
            }
            if let runtime = t3Runtime.exactEntry(sessionID: id) {
                state.host = .t3
                if let provider = runtime.provider {
                    state.source = provider.rawValue
                    state.providerID = nil
                }
                state.isWorking = runtime.isWorking
                if !runtime.isWorking {
                    state.lastEventAt = runtime.lastEventAt ?? state.lastEventAt
                }
            }
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                let wasFinished = sessions[index].finishedAt != nil
                changed = merge(state, into: &sessions[index]) || changed
                let isFinished = sessions[index].finishedAt != nil
                if !wasFinished, isFinished {
                    completionReviewDeadlines[id] = now.addingTimeInterval(Self.completionLingerWindow)
                } else if !isFinished {
                    completionReviewDeadlines.removeValue(forKey: id)
                }
            } else {
                let added = session(from: state, now: now)
                sessions.append(added)
                if added.finishedAt != nil {
                    let deadline = state.lastEventAt.addingTimeInterval(Self.completionLingerWindow)
                    if deadline >= now {
                        completionReviewDeadlines[id] = deadline
                    }
                }
                changed = true
            }
        }

        if changed {
            sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        }
    }

    private func currentT3RuntimeIndex(
        at now: Date = Date(),
        forceRefresh: Bool = false
    ) -> AgentT3RuntimeIndex {
        if forceRefresh || now.timeIntervalSince(t3RuntimeCacheReadAt) >= 2 {
            t3RuntimeCache = AgentT3RuntimeIndex.index()
            t3RuntimeCacheReadAt = now
        }
        return t3RuntimeCache
    }

    /// True when anything actually moved, so a no-op event does not republish
    /// and re-lay out the island.
    private func merge(
        _ state: AgentHookBridge.LiveSessionState,
        into session: inout AgentSession
    ) -> Bool {
        var changed = false
        let provider = Self.provider(for: state)

        if provider == .cursor,
           AgentSessionJump.origin(sessionID: session.id, provider: .cursor) == .cursorACP {
            if session.isOpenInClient != state.isWorking {
                session.isOpenInClient = state.isWorking
                changed = true
            }
        }

        if state.lastEventAt > session.lastActivityAt {
            session.lastActivityAt = state.lastEventAt
            changed = true
        }
        // Hooks stop arriving when a turn is interrupted or its terminal is
        // killed, and nothing says so. Silence that long is not work.
        let isWorking = state.isWorking
            && Date().timeIntervalSince(state.lastEventAt) < AgentHookBridge.silentWorkingWindow
        if session.isActive != isWorking {
            session.isActive = isWorking
            changed = true
        }
        // Every provider's turn-end hook marks the session finished, so its
        // row reads "Ready to review" and a later transcript parse does not
        // announce the same turn again.
        let finishedAt: Date? = state.isWorking
            ? nil
            : (state.finishedAt ?? (provider == .cursor ? state.lastEventAt : nil))
        if session.finishedAt != finishedAt {
            session.finishedAt = finishedAt
            changed = true
        }
        if session.provider != provider {
            session.provider = provider
            changed = true
        }
        if let host = state.host, session.host != host {
            session.host = host
            changed = true
        }
        if let bundleID = state.hostBundleID, session.hostBundleID != bundleID {
            session.hostBundleID = bundleID
            changed = true
        }
        if let detail = state.lastToolInputDescription, session.currentActivity != detail {
            session.currentActivity = detail
            changed = true
        }
        let combinedActivity = Self.mergeActivity(
            transcript: session.recentActivity,
            hook: state.recentActivity
        )
        if session.recentActivity != combinedActivity {
            session.recentActivity = combinedActivity
            changed = true
        }
        if let prompt = state.lastUserPrompt, session.lastUserPrompt != prompt {
            session.lastUserPrompt = Self.firstDisplayLine(prompt)
            changed = true
        }
        if let started = state.turnStartedAt, started > session.turnStartedAt ?? .distantPast {
            session.turnStartedAt = started
            changed = true
        }
        if let reply = state.lastAgentMessage, session.lastAgentMessage != reply {
            session.lastAgentMessage = reply
            changed = true
        }
        if let parent = state.parentSessionID, session.parentSessionID != parent {
            session.parentSessionID = parent
            changed = true
        }
        if !state.subagents.isEmpty, AgentSubagent.merge(state.subagents, into: &session.subagents) {
            changed = true
        }
        if let model = (session.provider == .cursor ? currentT3RuntimeIndex().exactEntry(sessionID: session.id)?.model
            ?? CursorConversationModels.model(for: session.id) : nil) ?? state.model, session.model != model {
            session.model = model
            changed = true
        }
        if session.workingDirectory == nil, let cwd = state.workingDirectory {
            session.workingDirectory = cwd
            session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
            changed = true
        }
        let named = session.displayName
        applyKnownTitle(to: &session)
        if session.displayName != named { changed = true }
        return changed
    }

    private func session(from state: AgentHookBridge.LiveSessionState, now: Date = Date()) -> AgentSession {
        var built = AgentSession(
            id: state.sessionID,
            provider: Self.provider(for: state),
            projectName: state.workingDirectory
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Session",
            lastActivityAt: state.lastEventAt
        )
        built.focusLabel = focusLabels[state.sessionID]
        built.workingDirectory = state.workingDirectory
        built.host = state.host
        built.hostBundleID = state.hostBundleID
        built.startedAt = state.firstSeen
        // The same silence rule as `merge`. A disk scan rebuilds the list
        // without hook-only sessions, and this path puts them back, so
        // trusting `isWorking` alone revived sessions whose turn ended
        // without a hook (a killed terminal, an automated run) as "running"
        // after every scan, for days.
        built.isActive = state.isWorking
            && now.timeIntervalSince(state.lastEventAt) < AgentHookBridge.silentWorkingWindow
        built.finishedAt = built.provider == .cursor && !state.isWorking ? state.lastEventAt : nil
        built.currentActivity = state.lastToolInputDescription
        built.model = (built.provider == .cursor ? currentT3RuntimeIndex().exactEntry(sessionID: built.id)?.model
            ?? CursorConversationModels.model(for: built.id) : nil) ?? state.model
        built.lastUserPrompt = state.lastUserPrompt.map(Self.firstDisplayLine)
        built.turnStartedAt = state.turnStartedAt
        built.lastAgentMessage = state.lastAgentMessage
        built.parentSessionID = state.parentSessionID
        _ = AgentSubagent.merge(state.subagents, into: &built.subagents)

        if !state.recentActivity.isEmpty {
            built.recentActivity = state.recentActivity
        } else if let detail = state.lastToolInputDescription {
            built.recentActivity = [
                AgentActivityEntry(
                    kind: AgentActivityEntry.Kind(rawValue: state.lastToolKindRaw ?? "")
                        ?? .message,
                    detail: detail,
                    at: state.lastEventAt
                )
            ]
        }
        applyKnownTitle(to: &built)
        return built
    }

    nonisolated private static func provider(for state: AgentHookBridge.LiveSessionState) -> AgentProviderID {
        if state.source == "cursor" { return .cursor }
        return AgentProviderID.fromHook(source: state.source, providerID: state.providerID)
            ?? .claude
    }

    private static func firstDisplayLine(_ text: String) -> String {
        return AgentToolLabel.truncated(AgentSessionPromptSummary.line(text), 120)
    }

    private static func mergeActivity(
        transcript: [AgentActivityEntry],
        hook: [AgentActivityEntry]
    ) -> [AgentActivityEntry] {
        guard !hook.isEmpty else { return transcript }
        var keys: Set<String> = []
        let merged = (transcript + hook).sorted { $0.at < $1.at }.filter { entry in
            let key = "\(entry.at.timeIntervalSince1970)|\(entry.kind.rawValue)|\(entry.detail)|\(entry.target ?? "")"
            return keys.insert(key).inserted
        }
        return Array(merged.suffix(40))
    }

    /// Hook events are the authoritative liveness signal    /// Hook events are the authoritative liveness signal — they arrive even for
    /// sessions launched by an IDE, which leave no terminal to watch.
    func applyLiveSignals(
        _ signals: [String: Date],
        waiting: Set<String>,
        decisions: [String: AgentHookBridge.DecisionNote] = [:]
    ) {
        guard !signals.isEmpty || !waiting.isEmpty || !decisions.isEmpty else { return }
        var changed = false

        for index in sessions.indices {
            let id = sessions[index].id
            if let note = decisions[id], sessions[index].nanoDecision != note {
                sessions[index].nanoDecision = note
                changed = true
            }
            if sessions[index].finishedAt == nil,
               let seen = signals[id], seen > sessions[index].lastActivityAt {
                sessions[index].lastActivityAt = seen
                sessions[index].isActive = true
                changed = true
            }
            let blocked = waiting.contains(id)
            if sessions[index].needsAttention != blocked {
                sessions[index].needsAttention = blocked
                changed = true
            }
        }

        if changed {
            sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        }
    }
}

// MARK: - Titles the client already has

/// Names the user typed into their own client.
///
/// Claude Code writes one small file per running session into
/// `~/.claude/sessions`, carrying the session's name and whether the user set
/// it. Only the user-set ones are read: the derived name is the project slug
/// plus two characters (`north-star-a0`), which says nothing the project name
/// did not and reads worse. That file is deleted with the process, so a rename
/// has to be picked up while the session runs.
private enum AgentClientNames {
    static func index() -> [String: String] {
        var found: [String: String] = [:]

        for directory in directories() {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization
                        .jsonObject(with: data) as? [String: Any],
                      let id = object["sessionId"] as? String,
                      (object["nameSource"] as? String) == "user",
                      let name = (object["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { continue }
                found[id] = name
            }
        }
        return found
    }

    /// Sibling of the transcript root: `<config>/projects` next to
    /// `<config>/sessions`.
    private static func directories() -> [URL] {
        var seen: Set<String> = []
        return AgentSessionParsers.claudeRoots()
            .map {
                $0.deletingLastPathComponent()
                    .appendingPathComponent("sessions", isDirectory: true)
            }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// Titles kept by the Claude desktop app.
///
/// It stores a record per session under Application Support with its own
/// `title` — the real sentence kind, "Video file access" — keyed to the
/// transcript's session ID by `cliSessionId`. `titleSource` says whether the
/// user typed it or the app generated it.
private enum AgentDesktopTitles {
    struct Entry: Sendable {
        let text: String
        let isUserSet: Bool
    }

    static func index(since cutoff: Date) -> [String: Entry] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude/claude-code-sessions",
                isDirectory: true
            )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var found: [String: Entry] = [:]
        for case let file as URL in enumerator
        where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            // These records are tens of kilobytes each and mostly permission
            // state. Only sessions recent enough to be on screen are read.
            guard let modified = (try? FileManager.default
                .attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                modified > cutoff,
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = object["cliSessionId"] as? String,
                let title = (object["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            else { continue }

            found[id] = Entry(
                text: title,
                isUserSet: (object["titleSource"] as? String) == "user"
            )
        }
        return found
    }
}

/// Titles shown by the Codex app for local threads.
///
/// Codex transcripts keep the conversation, but the short task name lives in
/// the app's thread index. The transcript's opening `title` is often the raw
/// first request; `threads.name` is the concise name shown in Codex itself.
enum AgentCodexThreadNames {
    static func index(
        databaseURL: URL? = nil,
        includeAppServer: Bool = false
    ) -> [String: String] {
        guard let databaseURL = databaseURL ?? defaultDatabaseURL() else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
        SELECT id, name
        FROM threads
        WHERE name IS NOT NULL AND TRIM(name) <> ''
        ORDER BY updated_at DESC
        LIMIT 500
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var names: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1)
            else { continue }
            let name = String(cString: nameText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names[String(cString: idText)] = name }
        }
        if includeAppServer {
            // The desktop app can hold an AI-generated or user-edited name
            // before it is checkpointed into `threads.name`. `thread/list` is
            // Codex's supported local view and repairs that exact gap. This is
            // only requested by a discovery scan, never by the hot hook path.
            names.merge(appServerIndex()) { _, appServerName in appServerName }
        }
        return names
    }

    static func names(fromAppServerLine data: Data, requestID: Int) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == requestID,
              let result = object["result"] as? [String: Any],
              let threads = result["data"] as? [[String: Any]]
        else { return nil }

        var names: [String: String] = [:]
        for thread in threads {
            guard let id = thread["id"] as? String,
                  let rawName = thread["name"] as? String
            else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names[id] = name }
        }
        return names
    }

    private static func appServerIndex() -> [String: String] {
        guard let executableURL = appServerExecutableURL() else { return [:] }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let collector = AgentCodexAppServerResponseCollector(requestID: 2)
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        environment["PATH"] = localBin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.consume(handle.availableData)
        }

        do {
            try process.run()
            try writeAppServerMessage(
                [
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": ["name": "nano", "version": "1"],
                        "capabilities": ["experimentalApi": true],
                    ],
                ],
                to: input.fileHandleForWriting
            )
            guard collector.initialized.wait(timeout: .now() + 2) == .success else {
                throw CocoaError(.coderReadCorrupt)
            }
            try writeAppServerMessage(
                ["method": "initialized", "params": [:]],
                to: input.fileHandleForWriting
            )
            try writeAppServerMessage(
                [
                    "id": 2,
                    "method": "thread/list",
                    "params": [
                        "limit": 100,
                        "sortKey": "updated_at",
                        "sortDirection": "desc",
                    ],
                ],
                to: input.fileHandleForWriting
            )
            _ = collector.completed.wait(timeout: .now() + 3)
        } catch {
            // SQLite remains a valid fallback when the CLI is absent, old, or
            // temporarily busy. Session monitoring must never depend on it.
        }

        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        return collector.result
    }

    private static func writeAppServerMessage(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    static func appServerExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // The ChatGPT desktop app bundles a native CLI, so it works even when
        // no node is on PATH; the ~/.local/bin symlink is a node script.
        var candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            home.appendingPathComponent(".local/bin/codex"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex")
            })
        }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func defaultDatabaseURL() -> URL? {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        let url = base.appendingPathComponent("state_5.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private final class AgentCodexAppServerResponseCollector: @unchecked Sendable {
    let initialized = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)

    private let requestID: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var names: [String: String] = [:]

    init(requestID: Int) {
        self.requestID = requestID
    }

    var result: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue
            else { continue }
            if id == 1 {
                initialized.signal()
            } else if id == requestID,
                      let parsed = AgentCodexThreadNames.names(
                        fromAppServerLine: line,
                        requestID: requestID
                      ) {
                names = parsed
                completed.signal()
            }
        }
        lock.unlock()
    }
}

/// Model identity shown by the Codex app for local threads.
///
/// Large rollouts are tail-read for performance, so their most recent
/// `turn_context` record is not guaranteed to be inside Nano's 256KB window.
/// The thread index is small and already carries the current model directly.
enum AgentCodexThreadModels {
    static func index(databaseURL: URL? = nil) -> [String: String] {
        guard let databaseURL = databaseURL ?? AgentCodexThreadNames.defaultDatabaseURL()
        else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
        SELECT id, model
        FROM threads
        WHERE model IS NOT NULL AND TRIM(model) <> ''
        ORDER BY updated_at DESC
        LIMIT 500
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var models: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let modelText = sqlite3_column_text(statement, 1)
            else { continue }
            let model = String(cString: modelText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty { models[String(cString: idText)] = model }
        }
        return models
    }
}

/// Authoritative run state for Cursor ACP sessions launched by T3 Code.
///
/// An ACP transcript says what happened, but it does not say whether its host
/// still has a turn running. T3 does: both its projected session and provider
/// runtime carry a lifecycle status. Keeping this small index beside the other
/// native metadata prevents a stopped T3 thread from being revived by an old
/// hook or a recently touched SQLite file.
struct AgentT3RuntimeIndex: Sendable {
    struct Entry: Equatable, Sendable {
        var threadID: String
        var providerSessionID: String?
        var provider: AgentProviderID?
        var workingDirectory: String?
        var isStopped: Bool
        var isWorking: Bool
        var lastEventAt: Date?
        var model: String?
        /// The thread name the host shows in its own sidebar.
        var title: String?
    }

    private var byProviderSessionID: [String: Entry] = [:]
    private var byThreadID: [String: Entry] = [:]

    var modelsByProviderSessionID: [String: String] {
        byProviderSessionID.reduce(into: [:]) { result, pair in
            guard let model = pair.value.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty
            else { return }
            result[pair.key] = model
        }
    }

    func exactEntry(sessionID: String) -> Entry? {
        byProviderSessionID[sessionID] ?? byThreadID[sessionID]
    }

    func entry(sessionID: String, workingDirectory: String?) -> Entry? {
        // Folder identity cannot establish conversation identity, even when
        // the neighbouring conversation has stopped.
        exactEntry(sessionID: sessionID)
    }

    static func index(databaseURL: URL = defaultDatabaseURL()) -> Self {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return Self() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else { return Self() }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        // The title is a nicety; liveness is not. A schema without it must
        // still index every session rather than hide them all.
        func sql(withTitle: Bool) -> String {
            """
            SELECT s.thread_id,
                   s.provider_session_id,
                   COALESCE(r.provider_name, s.provider_name),
                   s.status,
                   r.status,
                   s.updated_at,
                   r.last_seen_at,
                   r.runtime_payload_json,
                   s.active_turn_id\(withTitle ? ",\n       t.title" : "")
            FROM projection_thread_sessions s
            LEFT JOIN provider_session_runtime r ON r.thread_id = s.thread_id
            LEFT JOIN projection_threads t ON t.thread_id = s.thread_id
            WHERE t.deleted_at IS NULL
            ORDER BY COALESCE(r.last_seen_at, s.updated_at) DESC
            """
        }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql(withTitle: true), -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            guard sqlite3_prepare_v2(db, sql(withTitle: false), -1, &statement, nil) == SQLITE_OK
            else { return Self() }
        }
        guard let statement else { return Self() }
        defer { sqlite3_finalize(statement) }
        let hasTitleColumn = sqlite3_column_count(statement) > 9

        var result = Self()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadText = sqlite3_column_text(statement, 0) else { continue }
            let provider = sqliteString(statement, column: 2)?.lowercased()

            let payload = sqliteString(statement, column: 7).flatMap { raw -> [String: Any]? in
                guard let data = raw.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let directory = (payload?["cwd"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let sessionStatus = sqliteString(statement, column: 3)?.lowercased()
            let runtimeStatus = sqliteString(statement, column: 4)?.lowercased()
            let activeTurnID = sqliteString(statement, column: 8)
            // T3 runs `provider.stopAll` when it launches or quits, stamping
            // every stored thread's runtime row with that moment. It is the
            // host's lifecycle, not the conversation's; trusting it made
            // weeks-old threads reappear as freshly finished on every T3 launch.
            let runtimeStampIsHostLifecycle =
                (payload?["lastRuntimeEvent"] as? String) == "provider.stopAll"
            let stoppedStatuses: Set<String> = ["stopped", "completed", "failed", "cancelled"]
            let providerIdentity = provider.flatMap { AgentProviderID.fromHook(source: $0) }
            let storedSessionID = sqliteString(statement, column: 1)
            let recoveredSessionID: String?
            if storedSessionID == nil,
               providerIdentity == .cursor || providerIdentity == .grok {
                recoveredSessionID = providerSessionID(
                    threadID: String(cString: threadText),
                    databaseURL: databaseURL
                )
            } else {
                recoveredSessionID = nil
            }
            let entry = Entry(
                threadID: String(cString: threadText),
                providerSessionID: storedSessionID ?? recoveredSessionID,
                provider: providerIdentity,
                workingDirectory: directory?.isEmpty == false ? directory : nil,
                isStopped: sessionStatus.map(stoppedStatuses.contains) == true
                    || runtimeStatus.map(stoppedStatuses.contains) == true,
                isWorking: sessionStatus == "running" && activeTurnID?.isEmpty == false,
                lastEventAt: runtimeStampIsHostLifecycle
                    ? isoDate(sqliteString(statement, column: 5))
                    : isoDate(payload?["lastRuntimeEventAt"] as? String)
                        ?? isoDate(sqliteString(statement, column: 6))
                        ?? isoDate(sqliteString(statement, column: 5)),
                model: payload?["model"] as? String,
                title: (hasTitleColumn ? sqliteString(statement, column: 9) : nil)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            )
            if result.byThreadID[entry.threadID] == nil {
                result.byThreadID[entry.threadID] = entry
            }
            if let id = entry.providerSessionID, !id.isEmpty,
               result.byProviderSessionID[id] == nil {
                result.byProviderSessionID[id] = entry
            }
        }
        return result
    }

    /// Older T3 projections omit the ACP ID, but native runtime receipts retain
    /// it. Only structured protocol fields are read.
    ///
    /// A single tool result can make one log line run to several hundred
    /// kilobytes, so a fixed 64KB tail landed inside such a line most of the
    /// time mid-turn and found nothing. A miss made a live session look
    /// closed and every scan re-announced it as finished. Walk back in chunks
    /// until a receipt parses, and keep the answer: the ID is stable for the
    /// thread's lifetime, and the DB column wins whenever T3 fills it in.
    private static let recoveredSessionIDs = RecoveredSessionIDs()

    static func providerSessionID(
        threadID: String,
        databaseURL: URL,
        chunkSize: Int = 256 * 1024,
        scanLimit: Int = 4 * 1024 * 1024
    ) -> String? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        if let cached = recoveredSessionIDs[threadID] { return cached }
        let url = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("logs/provider/events.\(threadID).log")
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return nil }

        var cursor = Int(clamping: end)
        // Bytes before the first newline of a chunk may be the tail of a line
        // that started in the previous (earlier) chunk; carry them back.
        var carry = Data()
        while cursor > 0, Int(clamping: end) - cursor < scanLimit {
            let start = max(cursor - chunkSize, 0)
            try? file.seek(toOffset: UInt64(start))
            guard var data = try? file.read(upToCount: cursor - start) else { break }
            data.append(carry)
            if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                carry = data[..<newline]
                data = data[data.index(after: newline)...]
            } else {
                carry = Data()
            }
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                if let id = sessionID(inReceipt: line) {
                    recoveredSessionIDs[threadID] = id
                    return id
                }
            }
            cursor = start
        }
        return nil
    }

    private static func sessionID(inReceipt line: Data) -> String? {
        guard let start = line.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: line[start...]) as? [String: Any]
        else { return nil }
        let event = object["event"] as? [String: Any]
        let raw = object["raw"] as? [String: Any]
        let payload = (event?["payload"] as? [String: Any]) ?? (raw?["payload"] as? [String: Any])
        guard let id = payload?["sessionId"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private final class RecoveredSessionIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String: String] = [:]

        subscript(threadID: String) -> String? {
            get { lock.withLock { ids[threadID] } }
            set { lock.withLock { ids[threadID] = newValue } }
        }
    }

    private static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/state.sqlite")
    }

    private static func sqliteString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: text)
    }

    private static func isoDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return NanoISO8601.date(text)
    }
}

/// Conversation metadata maintained by Cursor's Agents Window.
///
/// Cursor 3 stores the exact sidebar title, context percentage, archive state,
/// and subagent identity in the global `composerHeaders` table. Those native
/// fields are stronger signals than inferring identity or liveness from jsonl
/// transcript shape.
enum AgentCursorConversationMetadata {
    struct Entry: Equatable, Sendable {
        var name: String?
        var contextFraction: Double?
        var isOpenInClient: Bool
    }

    static func index(databaseURL: URL? = nil) -> [String: Entry] {
        guard let databaseURL = databaseURL ?? defaultDatabaseURL() else { return [:] }

        // A Cursor database left in WAL mode cannot be opened read-only when
        // Cursor has removed the sidecar and Nano cannot create a replacement.
        // Immutable mode reads the last checkpointed main database without
        // attempting to create `-wal`/`-shm`; use the live WAL whenever present.
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let hasWAL = FileManager.default.fileExists(atPath: walURL.path)
        let location = hasWAL ? databaseURL.path : databaseURL.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (hasWAL ? 0 : SQLITE_OPEN_URI)

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            location,
            &db,
            flags,
            nil
        ) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
        SELECT composerId, isArchived, isSubagent, value
        FROM composerHeaders
        ORDER BY lastUpdatedAt DESC
        LIMIT 1000
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var entries: [String: Entry] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let valueText = sqlite3_column_text(statement, 3)
            else { continue }
            let id = String(cString: idText)
            let data = Data(String(cString: valueText).utf8)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let name = (object?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let percent = number(object?["contextUsagePercent"])
            let archived = sqlite3_column_int(statement, 1) != 0
            let subagent = sqlite3_column_int(statement, 2) != 0
            entries[id] = Entry(
                name: name?.isEmpty == false ? name : nil,
                contextFraction: percent.map { min(max($0 / 100, 0), 1) },
                // Cursor keeps every non-archived Agents Window conversation
                // in the active project list. `selectedAgent` names only the
                // focused tab, not every session the user has open.
                isOpenInClient: !archived && !subagent
            )
        }
        return entries
    }

    static func defaultDatabaseURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }
}

/// Devin's hook payloads carry no `cwd`, `model`, or title — just a
/// `session_id` that matches the `id` in its own session store. Reading that
/// store is how a hook-only Devin row gets a real name instead of the raw
/// first prompt.
enum AgentDevinSessionMetadata {
    struct Entry: Equatable, Sendable {
        var title: String?
        var model: String?
        var workingDirectory: String?
        /// `created_at` / `last_activity_at`, stored as epoch seconds upstream.
        var createdAt: Date?
        var lastActivityAt: Date?
    }

    /// `since` bounds the scan by `last_activity_at` (epoch seconds). The
    /// default suits the naming path; the session parser passes the shared
    /// recency cutoff and a tight limit, since the WAL churns while Devin runs.
    static func index(
        databaseURL: URL? = nil,
        since cutoff: Int? = nil,
        limit: Int = 500
    ) -> [String: Entry] {
        guard let databaseURL = databaseURL ?? defaultDatabaseURL() else { return [:] }

        // Same WAL caveat as Cursor's store: a missing `-wal` sidecar that
        // Nano cannot create means read-only open fails, so fall back to the
        // immutable view of the last checkpointed database.
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let hasWAL = FileManager.default.fileExists(atPath: walURL.path)
        let location = hasWAL ? databaseURL.path : databaseURL.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (hasWAL ? 0 : SQLITE_OPEN_URI)

        var db: OpaquePointer?
        guard sqlite3_open_v2(location, &db, flags, nil) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        // Rows hidden in Devin's own UI are hidden here too, and anything stale
        // enough to fall outside it is not a session the island is showing.
        let sinceSeconds = cutoff ?? (Int(Date().timeIntervalSince1970) - 7 * 24 * 3600)
        let sql = """
        SELECT id, title, model, working_directory, created_at, last_activity_at
        FROM sessions
        WHERE hidden = 0 AND last_activity_at > \(sinceSeconds)
        ORDER BY last_activity_at DESC
        LIMIT \(max(limit, 1))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        func column(_ index: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, index) else { return nil }
            let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        var entries: [String: Entry] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = column(0) else { continue }
            func epoch(_ index: Int32) -> Date? {
                let seconds = sqlite3_column_int64(statement, index)
                return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
            }
            entries[id] = Entry(
                title: column(1),
                model: column(2),
                workingDirectory: column(3),
                createdAt: epoch(4),
                lastActivityAt: epoch(5)
            )
        }
        return entries
    }

    static func defaultDatabaseURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/cli/sessions.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Names the user typed into Nano itself, which outrank every other source.
///
/// Kept in Nano's own storage rather than written back to the agent's files:
/// those belong to the client, and a session that has exited no longer has any.
enum AgentSessionRenames {
    static func load() -> [String: String] {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return names
    }

    static func save(_ names: [String: String]) {
        guard let url = fileURL(),
              let data = try? JSONSerialization.data(withJSONObject: names)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        try? NanoStorage.directory("sessions").appendingPathComponent("names.json")
    }
}

/// Sessions cleared from the island, kept across launches so a relaunch does
/// not bring back everything the user already put away.
enum AgentSessionDismissals {
    /// Past this a cleared session has long since left the list on its own.
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    static var defaultURL: URL? {
        try? NanoStorage.directory("sessions").appendingPathComponent("dismissed.json")
    }

    static func load(from url: URL?, now: Date = Date()) -> [String: Date] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let stamps = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return [:] }
        return stamps.mapValues(Date.init(timeIntervalSince1970:))
            .filter { now.timeIntervalSince($0.value) < retention }
    }

    static func save(_ dismissals: [String: Date], to url: URL?) {
        guard let url,
              let data = try? JSONSerialization.data(
                  withJSONObject: dismissals.mapValues(\.timeIntervalSince1970)
              )
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Everything already known about a session's name before its transcript is
/// read, gathered once per scan.
fileprivate struct AgentKnownTitles: Sendable {
    var clientNames: [String: String] = [:]
    var desktop: [String: AgentDesktopTitles.Entry] = [:]
    var codex: [String: String] = [:]
    var codexModels: [String: String] = [:]
    var cursor: [String: AgentCursorConversationMetadata.Entry] = [:]

    static func read(
        since cutoff: Date,
        includeCodexAppServer: Bool = false,
        cursorMetadata: [String: AgentCursorConversationMetadata.Entry]? = nil
    ) -> AgentKnownTitles {
        AgentKnownTitles(
            clientNames: AgentClientNames.index(),
            desktop: AgentDesktopTitles.index(since: cutoff),
            codex: AgentCodexThreadNames.index(includeAppServer: includeCodexAppServer),
            codexModels: AgentCodexThreadModels.index(),
            cursor: cursorMetadata ?? AgentCursorConversationMetadata.index()
        )
    }

    /// Offered weakest first, so the strongest source present wins whatever
    /// order they happen to exist in.
    func apply(to session: inout AgentSession) {
        if session.provider == .codex {
            session.offer(codex[session.id], from: .client)
            if session.model == nil { session.model = codexModels[session.id] }
        }
        if session.provider == .cursor, let entry = cursor[session.id] {
            session.offer(entry.name, from: .client)
            session.contextFractionOverride = entry.contextFraction
            session.isOpenInClient = entry.isOpenInClient
            if entry.isOpenInClient {
                session.finishedAt = nil
            } else {
                session.finishedAt = session.finishedAt ?? session.lastActivityAt
                session.isActive = false
            }
        }
        if let entry = desktop[session.id] {
            session.offer(entry.text, from: entry.isUserSet ? .userNamed : .client)
        }
        session.offer(clientNames[session.id], from: .userNamed)
    }
}

// MARK: - Parsing

enum AgentSessionParsers {
    /// Only the newest sessions are worth showing, and only their tail says
    /// what the agent is doing now. Both bounds matter: this machine has 175
    /// Codex transcripts touched in the last week totalling 4.4GB, several
    /// over 200MB, so reading them whole freezes the app.
    private static let recentCutoff: TimeInterval = 60 * 60 * 24 * 3
    private static let maxSessions = 20
    private static let tailBytes: Int64 = 256_000
    /// Kept well past what the section shows: the tools list caps its viewport
    /// at eight rows and scrolls, so a 10-entry history would leave almost
    /// nothing to scroll to.
    private static let activityTail = 40

    private struct Candidate {
        let url: URL
        let provider: AgentProviderID
        let modified: Date
        let size: Int64
        let projectDirectory: String?
    }

    /// Re-parses only files that an existing watcher reported as changed.
    /// Discovery scans own additions and removals; known-file writes must not
    /// walk every provider tree or re-read twenty unrelated transcript tails.
    static func parseIncrementalChanges(
        _ changes: [String: AgentProviderID],
        cursorMetadata: [String: AgentCursorConversationMetadata.Entry]? = nil
    ) -> [AgentSession] {
        let known = AgentKnownTitles.read(
            since: Date().addingTimeInterval(-recentCutoff),
            cursorMetadata: cursorMetadata
        )
        return parseIncrementalResult(changes, knownTitles: known).sessions
    }

    fileprivate static func parseIncrementalResult(
        _ changes: [String: AgentProviderID],
        knownTitles cachedKnownTitles: AgentKnownTitles?
    ) -> AgentSessionIncrementalParseResult {
        let known = cachedKnownTitles ?? AgentKnownTitles.read(
            since: Date().addingTimeInterval(-recentCutoff)
        )
        var refreshed: [AgentSession] = []

        for path in changes.keys.sorted() {
            guard let provider = changes[path] else { continue }
            let url = URL(fileURLWithPath: path)
            let parsed: [AgentSession]

            switch provider {
            case .cursor where url.lastPathComponent == "state.vscdb"
                || url.lastPathComponent == "state.vscdb-wal":
                // The caller promotes an empty metadata-only refresh into one
                // discovery pass, rebuilding every Cursor row with fresh
                // header names and presentation state.
                parsed = []
            case .cursor where url.pathExtension != "jsonl":
                parsed = parseCursorStore(at: url.deletingLastPathComponent(), fullHistory: false)
                    .map { [$0] } ?? []
            case .opencode:
                let databaseURL = url.lastPathComponent.hasSuffix("-wal")
                    ? URL(fileURLWithPath: String(url.path.dropLast(4)))
                    : url
                parsed = openCodeSessions(databaseURL: databaseURL)
            case .devin:
                // The WAL rewrites on every statement Devin records; the read
                // stays one indexed query either way.
                parsed = devinSessions(databaseURL: watchBase(for: url))
            case .cline:
                parsed = clineSessionsIn(databaseURL: watchBase(for: url))
            case .kilo:
                parsed = kiloSessionsIn(databaseURL: watchBase(for: url))
            case .goose:
                parsed = gooseSessionsIn(databaseURL: watchBase(for: url))
            case .qwen:
                if url.pathExtension == "jsonl" {
                    parsed = qwenSession(file: url).map { [$0] } ?? []
                } else {
                    parsed = qwenSessions()
                }
            case .grok:
                parsed = parseGrokSession(
                    at: url.deletingLastPathComponent(),
                    known: known,
                    fullHistory: false
                ).map { [$0] } ?? []
            default:
                parsed = parseChangedTranscript(at: url, provider: provider, known: known)
                    .map { [$0] } ?? []
            }

            refreshed.append(contentsOf: parsed)
        }

        for index in refreshed.indices {
            known.apply(to: &refreshed[index])
        }

        var merged = mergeSessionsByID(refreshed)
        CursorConversationModels.apply(to: &merged)
        return AgentSessionIncrementalParseResult(
            sessions: merged.sorted { $0.lastActivityAt > $1.lastActivityAt },
            knownTitles: known,
            refreshedKnownTitles: cachedKnownTitles == nil
        )
    }

    private static func needsMetadataRecovery(_ session: AgentSession) -> Bool {
        session.recentActivity.isEmpty || session.lastUserPrompt == nil || session.model == nil
    }

    private static func parseChangedTranscript(
        at url: URL,
        provider: AgentProviderID,
        known: AgentKnownTitles
    ) -> AgentSession? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }

        let projectDirectory: String?
        switch provider {
        case .claude, .pi:
            projectDirectory = url.deletingLastPathComponent().lastPathComponent
        case .cursor:
            let transcriptRoot = url.deletingLastPathComponent().deletingLastPathComponent()
            projectDirectory = transcriptRoot.deletingLastPathComponent().lastPathComponent
        default:
            projectDirectory = nil
        }

        let candidate = Candidate(
            url: url,
            provider: provider,
            modified: (attributes[.modificationDate] as? Date) ?? Date(),
            size: (attributes[.size] as? Int64) ?? 0,
            projectDirectory: projectDirectory
        )
        guard let session = parse(candidate, known: known) else { return nil }
        if needsMetadataRecovery(session), candidate.size > tailBytes,
           wideRecoveries.withLock({ $0.insert(url.path).inserted }) {
            return parse(candidate, known: known, wideTail: true) ?? session
        }
        return session
    }

    /// Transcripts already given their one wide read this launch.
    ///
    /// A long turn pushes the last prompt out of the narrow tail for good, so
    /// without this every write to that session re-read eight megabytes. The
    /// store keeps what the wide read recovered and `combine` carries it
    /// forward; anything newer is in the narrow tail by definition.
    private static let wideRecoveries = OSAllocatedUnfairLock(initialState: Set<String>())

    fileprivate static func parseRecentResult() -> AgentSessionParseResult {
        var candidates = claudeCandidates() + codexCandidates() + cursorCandidates()
            + piCandidates()
        candidates.sort { $0.modified > $1.modified }
        // Read once for the whole scan rather than per transcript.
        let known = AgentKnownTitles.read(
            since: Date().addingTimeInterval(-recentCutoff),
            includeCodexAppServer: true
        )
        let openCursorIDs = Set(
            known.cursor.compactMap { id, entry in entry.isOpenInClient ? id : nil }
        )
        var recentCandidates = Array(candidates.prefix(maxSessions))
        var candidatePaths = Set(recentCandidates.map { $0.url.standardizedFileURL.path })
        for candidate in candidates where candidate.provider == .cursor
            && openCursorIDs.contains(candidate.url.deletingPathExtension().lastPathComponent) {
            let path = candidate.url.standardizedFileURL.path
            if candidatePaths.insert(path).inserted { recentCandidates.append(candidate) }
        }
        var sessions = recentCandidates.compactMap { candidate in
            let session = parse(candidate, known: known)

            // Image records can displace metadata while leaving a new tool call.
            if let session, needsMetadataRecovery(session), candidate.size > tailBytes {
                return parse(candidate, known: known, wideTail: true) ?? session
            }
            return session
        }

        // SQLite-backed sources join after the file walk; there is no tail to read.
        let cursorStores = cursorStoreDirectories()
        let databaseURL = openCodeDatabaseURL()
        let devinDatabaseURL = AgentDevinSessionMetadata.defaultDatabaseURL()
        let clineDirs = TokenScanners.clineDirectories()
        let kiloURL = TokenScanners.kiloDatabaseURL()
        let gooseURLs = TokenScanners.gooseDatabaseURLs()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let qwenFiles = qwenSessionFiles(roots: [TokenScanners.qwenRuntimeDirectory()])
        sessions += cursorStoreSessions(directories: cursorStores)
        sessions += openCodeSessions(databaseURL: databaseURL)
        sessions += devinSessions(databaseURL: devinDatabaseURL)
        sessions += clineSessions(directories: clineDirs)
        sessions += kiloSessions(databaseURL: kiloURL)
        sessions += gooseSessions(databaseURLs: gooseURLs)
        sessions += qwenFiles.compactMap {
            qwenSession(file: $0.url, modified: $0.modified, size: $0.size)
        }
        let grokDirectories = grokSessionDirectories()
        sessions += grokDirectories.compactMap {
            parseGrokSession(at: $0, known: known, fullHistory: false)
        }.filter(\.hasVisibleWork)
        sessions = mergeSessionsByID(sessions)
        for index in sessions.indices {
            known.apply(to: &sessions[index])
        }
        CursorConversationModels.apply(to: &sessions)
        sessions = limitRecentSessions(sessions)
        var monitoredFiles = recentCandidates.map(\.url)
        var fileProviders: [String: AgentProviderID] = [:]
        for candidate in recentCandidates {
            fileProviders[candidate.url.standardizedFileURL.path] = candidate.provider
        }
        for directory in cursorStores.prefix(maxSessions) {
            for file in cursorStoreWatchFiles(in: directory) {
                monitoredFiles.append(file)
                fileProviders[file.standardizedFileURL.path] = .cursor
            }
        }
        if let cursorDatabase = AgentCursorConversationMetadata.defaultDatabaseURL() {
            let cursorDatabaseFiles = [
                cursorDatabase,
                URL(fileURLWithPath: cursorDatabase.path + "-wal")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            monitoredFiles += cursorDatabaseFiles
            for file in cursorDatabaseFiles {
                fileProviders[file.standardizedFileURL.path] = .cursor
            }
        }
        if let databaseURL {
            let databaseFiles = [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            monitoredFiles += databaseFiles
            for file in databaseFiles {
                fileProviders[file.standardizedFileURL.path] = .opencode
            }
        }
        if let devinDatabaseURL {
            let devinDatabaseFiles = [
                devinDatabaseURL,
                URL(fileURLWithPath: devinDatabaseURL.path + "-wal")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            monitoredFiles += devinDatabaseFiles
            for file in devinDatabaseFiles {
                fileProviders[file.standardizedFileURL.path] = .devin
            }
        }
        for file in clineDatabaseFiles(directories: clineDirs) {
            monitoredFiles.append(file)
            fileProviders[file.standardizedFileURL.path] = .cline
        }
        let kiloFiles = [
            kiloURL,
            URL(fileURLWithPath: kiloURL.path + "-wal")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        monitoredFiles += kiloFiles
        for file in kiloFiles {
            fileProviders[file.standardizedFileURL.path] = .kilo
        }
        let gooseFiles = gooseURLs.flatMap { store in
            [store, URL(fileURLWithPath: store.path + "-wal")]
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        monitoredFiles += gooseFiles
        for file in gooseFiles {
            fileProviders[file.standardizedFileURL.path] = .goose
        }
        // Watching each chat file also reserves its `chats` directory, so new
        // sessions under an already-seen project surface as directory changes.
        for file in qwenFiles {
            monitoredFiles.append(file.url)
            fileProviders[file.url.standardizedFileURL.path] = .qwen
        }
        for directory in grokDirectories.prefix(maxSessions) {
            for name in ["updates.jsonl", "summary.json", "events.jsonl"] {
                let file = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                monitoredFiles.append(file)
                fileProviders[file.standardizedFileURL.path] = .grok
            }
        }
        return AgentSessionParseResult(
            sessions: sessions,
            monitoredFiles: monitoredFiles,
            monitoredFileProviders: fileProviders,
            knownTitles: known
        )
    }

    /// The global parsing cap must not erase a provider session that the
    /// provider still lists as open. Fill the remaining slots with ordinary
    /// recency, then restore chronological order for display.
    static func limitRecentSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        let sorted = sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        // Only recent open conversations earn a reserved slot. Cursor keeps
        // every unarchived chat "open", and reserving all of them let weeks
        // of old chats crowd live sessions out of the cap.
        let reservationCutoff = Date().addingTimeInterval(-AgentSessionStore.lingerWindow)
        let openCursor = sorted.filter {
            $0.provider == .cursor && $0.isOpenInClient == true
                && ($0.isActive || $0.lastActivityAt > reservationCutoff)
        }
        let reserved = Set(openCursor.map(\.id))
        let remainder = sorted.filter { !reserved.contains($0.id) }
        return Array(
            (openCursor + Array(remainder.prefix(max(maxSessions - openCursor.count, 0))))
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
                .prefix(maxSessions)
        )
    }

    /// Reserve provider roots and live transcript parents before spending the
    /// remaining budget. Walk each tree in turn, newest branches first, so a
    /// large archive in one provider cannot starve another provider's discovery.
    /// 256, not 1,024: each watch holds a descriptor, and the stress test
    /// found 1,026 open. Branches are taken newest first, so the ones left
    /// out are old archives; a session that appears there is still found by
    /// its hook or by the next reconciliation pass a few seconds later.
    static func filesystemMonitoringDirectories(
        limit: Int = 256,
        roots suppliedRoots: [URL]? = nil,
        activeFiles: [URL] = [],
        now: Date = Date()
    ) -> [URL] {
        guard limit > 0 else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexBase = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        let roots = suppliedRoots ?? (sessionDiscoveryRoots()
            + [codexBase.appendingPathComponent("sessions", isDirectory: true)])

        var directories: [URL] = []
        var seen: Set<String> = []

        func reserve(_ requested: URL) {
            var url = requested
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
                url.deleteLastPathComponent()
            }
            guard directories.count < limit,
                  seen.insert(url.standardizedFileURL.path).inserted else { return }
            directories.append(url)
        }

        roots.forEach(reserve)
        activeFiles.map { $0.deletingLastPathComponent() }.forEach(reserve)
        if suppliedRoots == nil {
            recentCodexDiscoveryDirectories(now: now).forEach(reserve)
        }

        var queues = roots.map { [$0] }
        var expanded: Set<String> = []
        while directories.count < limit {
            var progressed = false
            for index in queues.indices where !queues[index].isEmpty && directories.count < limit {
                let next = queues[index].removeLast()
                guard expanded.insert(next.standardizedFileURL.path).inserted else { continue }
                progressed = true
                reserve(next)
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: next,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                let sorted = children.compactMap { url -> (URL, Date)? in
                    guard let values = try? url.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
                    ]), values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                    return (url, values.contentModificationDate ?? .distantPast)
                }.sorted {
                    if $0.1 != $1.1 { return $0.1 < $1.1 }
                    return $0.0.path < $1.0.path
                }
                queues[index].append(contentsOf: sorted.map(\.0))
            }
            if !progressed { break }
        }
        return directories
    }

    /// Include absent day paths in the metadata probe: creating the first
    /// rollout after midnight is detectable even if a parent event was lost.
    static func recentCodexDiscoveryDirectories(now: Date = Date(), base: URL? = nil) -> [URL] {
        let root = base ?? (ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
            .appendingPathComponent("sessions", isDirectory: true)
        var result = [root]
        // Hosts may write either local or UTC date partitions.
        for timeZone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            for offset in 0..<3 {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
                let yearURL = root.appendingPathComponent(String(format: "%04d", year))
                let monthURL = yearURL.appendingPathComponent(String(format: "%02d", month))
                result += [yearURL, monthURL, monthURL.appendingPathComponent(String(format: "%02d", day))]
            }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - Discovery (stat only, no reads)

    private static func claudeCandidates() -> [Candidate] {
        var found: [Candidate] = []
        let cutoff = Date().addingTimeInterval(-recentCutoff)

        for root in claudeRoots() {
            guard let projects = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            for directory in projects {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                )) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)),
                          let modified = values.contentModificationDate,
                          modified > cutoff
                    else { continue }
                    found.append(Candidate(
                        url: file,
                        provider: .claude,
                        modified: modified,
                        size: Int64(values.fileSize ?? 0),
                        projectDirectory: directory.lastPathComponent
                    ))
                }
            }
        }
        return found
    }

    private static func codexCandidates() -> [Candidate] {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: base.appendingPathComponent("sessions", isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [Candidate] = []
        let cutoff = Date().addingTimeInterval(-recentCutoff)
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified > cutoff
            else { continue }
            found.append(Candidate(
                url: file,
                provider: .codex,
                modified: modified,
                size: (attributes[.size] as? Int64) ?? 0,
                projectDirectory: nil
            ))
        }
        return found
    }

    /// Every on-disk tree a supported CLI writes, regardless of which host
    /// spawned the process. Cursor keeps three unsynced stores; missing any
    /// one of them is how ACP clients (Zed, JetBrains, T3, a raw `agent acp`)
    /// vanish from the island.
    static func sessionDiscoveryRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return claudeRoots()
            + cursorStoreRoots()
            + [
                home.appendingPathComponent(".cursor/projects", isDirectory: true),
                home.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
                grokHome().appendingPathComponent("sessions", isDirectory: true),
                openCodeDataDirectoryURL(),
            ]
    }

    /// Cursor CLI transcripts use the same message/content/tool blocks as
    /// Claude, but live under each project's `agent-transcripts` directory.
    /// They were already parseable; discovery simply never handed them to the
    /// shared parser.
    private static func cursorCandidates() -> [Candidate] {
        cursorTranscriptCandidates(
            in: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/projects", isDirectory: true)
        )
    }

    /// Cursor IDE writes `~/.cursor/projects/<project>/agent-transcripts/<id>/<id>.jsonl`.
    /// That tree is separate from CLI/ACP `chats` and `acp-sessions` stores, so
    /// a desktop Cursor chat is invisible unless this walk runs.
    static func cursorTranscriptURLs(in root: URL) -> [URL] {
        cursorTranscriptCandidates(in: root).map(\.url)
    }

    private static func cursorTranscriptCandidates(in root: URL) -> [Candidate] {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-recentCutoff)
        var found: [Candidate] = []
        for project in projects {
            let transcriptRoot = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: transcriptRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for directory in sessions {
                let file = directory.appendingPathComponent("\(directory.lastPathComponent).jsonl")
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified > cutoff
                else { continue }
                found.append(Candidate(
                    url: file,
                    provider: .cursor,
                    modified: modified,
                    size: (attributes[.size] as? Int64) ?? 0,
                    projectDirectory: project.lastPathComponent
                ))
            }
        }
        return found
    }

    /// Pi writes Claude-shaped JSONL under `~/.pi/agent/sessions`. Hooks cover
    /// liveness when they fire; this is the disk fallback for the same tree.
    private static func piCandidates() -> [Candidate] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [Candidate] = []
        let cutoff = Date().addingTimeInterval(-recentCutoff)
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified > cutoff
            else { continue }
            found.append(Candidate(
                url: file,
                provider: .pi,
                modified: modified,
                size: (attributes[.size] as? Int64) ?? 0,
                projectDirectory: file.deletingLastPathComponent().lastPathComponent
            ))
        }
        return found
    }

    // MARK: - Grok CLI

    private static func grokHome() -> URL {
        ProcessInfo.processInfo.environment["GROK_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok", isDirectory: true)
    }

    /// Each session is a directory with `summary.json` plus an ACP
    /// `updates.jsonl`. Discovery is the summary; activity is the log tail.
    private static func grokSessionDirectories(sessionID: String? = nil) -> [URL] {
        let root = grokHome().appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-recentCutoff)
        var found: [(Date, URL)] = []
        for case let file as URL in enumerator where file.lastPathComponent == "summary.json" {
            let directory = file.deletingLastPathComponent()
            if let sessionID, directory.lastPathComponent != sessionID { continue }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  sessionID != nil || modified > cutoff
            else { continue }
            found.append((modified, directory))
        }
        found.sort { $0.0 > $1.0 }
        return found.prefix(maxSessions).map(\.1)
    }

    static func parseGrokSession(
        at directory: URL,
        fullHistory: Bool = false
    ) -> AgentSession? {
        parseGrokSession(at: directory, known: AgentKnownTitles(), fullHistory: fullHistory)
    }

    private static func parseGrokSession(
        at directory: URL,
        known: AgentKnownTitles,
        fullHistory: Bool
    ) -> AgentSession? {
        let summaryURL = directory.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let info = object["info"] as? [String: Any] ?? [:]
        let id = (info["id"] as? String) ?? directory.lastPathComponent
        let cwd = info["cwd"] as? String
        let attributes = try? FileManager.default.attributesOfItem(atPath: summaryURL.path)
        let modified = (attributes?[.modificationDate] as? Date)
            ?? (object["last_active_at"] as? String).flatMap(date(fromISO:))
            ?? (object["updated_at"] as? String).flatMap(date(fromISO:))
            ?? Date()

        var session = AgentSession(
            id: id,
            provider: .grok,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? directory.deletingLastPathComponent().lastPathComponent,
            lastActivityAt: modified
        )
        session.workingDirectory = cwd
        session.model = (object["current_model_id"] as? String)
            ?? (object["model"] as? String)
        session.startedAt = (object["created_at"] as? String).flatMap(date(fromISO:))
        session.offer(
            (object["generated_title"] as? String) ?? (object["session_summary"] as? String),
            from: .aiTitle
        )
        applyGrokSignals(directory.appendingPathComponent("signals.json"), to: &session)
        applyGrokUpdates(
            directory.appendingPathComponent("updates.jsonl"),
            to: &session,
            fullHistory: fullHistory
        )
        if session.gitBranch == nil {
            session.gitBranch = gitBranch(at: session.workingDirectory)
        }
        if session.contextWindow == nil {
            session.contextWindow = AgentSession.inferredContextWindow(for: session.model)
        }
        session.offer(agentPhrase(session), from: .agentPhrase)
        known.apply(to: &session)
        return session
    }

    private static func applyGrokSignals(_ url: URL, to session: inout AgentSession) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if session.model == nil {
            session.model = (object["primaryModelId"] as? String)
                ?? (object["modelsUsed"] as? [String])?.first
        }
        if let used = object["contextTokensUsed"] as? Int, used > 0 {
            session.contextUsed = used
        }
        if let window = object["contextWindowTokens"] as? Int, window > 0 {
            session.contextWindow = window
        }
    }

    private static func applyGrokUpdates(
        _ url: URL,
        to session: inout AgentSession,
        fullHistory: Bool
    ) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let text: String?
        if fullHistory, size <= fullReadCeiling {
            text = try? String(contentsOf: url, encoding: .utf8)
        } else {
            text = tail(of: url, size: size, bytes: tailBytes)
        }
        guard let text else { return }

        var activity: [AgentActivityEntry] = []
        var focus: [String: Double] = [:]
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail that started mid-file loses its first (partial) line. A
        // whole-file read, including a small session under the tail window,
        // starts at byte 0 and that line is intact.
        if !fullHistory, size > tailBytes, !lines.isEmpty { lines.removeFirst() }
        var agentReply = ""

        for (index, line) in lines.enumerated() {
            guard let object = json(from: line) else { continue }
            let params = object["params"] as? [String: Any]
            let update = (params?["update"] as? [String: Any]) ?? [:]
            let kind = update["sessionUpdate"] as? String
            let at = grokUpdateDate(object, params: params)

            if let model = ((update["_meta"] as? [String: Any])?["modelId"] as? String)
                ?? ((params?["_meta"] as? [String: Any])?["modelId"] as? String) {
                session.model = model
            }

            switch kind {
            case "user_message_chunk":
                if let prompt = grokText(update["content"]),
                   !prompt.isEmpty, !isSynthetic(prompt) {
                    session.lastUserPrompt = firstLine(prompt)
                    agentReply = ""
                }
            case "agent_message_chunk":
                if let text = grokText(update["content"]) { agentReply += text }
            case "tool_call", "tool_call_update":
                let tool = ((update["_meta"] as? [String: Any])?["x.ai/tool"] as? [String: Any])
                let name = (tool?["name"] as? String)
                    ?? (update["title"] as? String)
                    ?? "tool"
                let input = (update["rawInput"] as? [String: Any])
                    ?? (tool?["input"] as? [String: Any])
                    ?? [:]
                let described = AgentToolLabel.describe(tool: name, input: input)
                activity.append(AgentActivityEntry(
                    kind: described.kind,
                    detail: described.detail,
                    target: described.target,
                    at: at
                ))
                session.currentActivity = described.detail
                let recency = 0.5 + Double(index) / Double(max(lines.count, 1))
                if let path = described.target ?? grokToolPath(input) {
                    let leaf = URL(fileURLWithPath: path).lastPathComponent
                    focus[leaf, default: 0] += (described.kind == .edit ? 3 : 1) * recency
                }
            case "turn_completed":
                if let usage = update["usage"] as? [String: Any] {
                    let used = int(usage["totalTokens"])
                    if used > 0 { session.contextUsed = used }
                }
            default:
                break
            }
        }

        if let excerpt = AgentSessionPromptSummary.agentExcerpt(agentReply) {
            session.lastAgentMessage = excerpt
        }
        session.focusScores = Dictionary(
            uniqueKeysWithValues: focus
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { ($0.key, $0.value) }
        )
        if !activity.isEmpty {
            session.recentActivity = Array(collapseRepeats(activity).suffix(activityTail))
        }
    }

    private static func grokUpdateDate(
        _ object: [String: Any],
        params: [String: Any]?
    ) -> Date {
        if let seconds = object["timestamp"] as? Double, seconds > 0 {
            let epoch = seconds > 1e12 ? seconds / 1000 : seconds
            return Date(timeIntervalSince1970: epoch)
        }
        if let seconds = object["timestamp"] as? Int, seconds > 0 {
            let epoch = seconds > 1_000_000_000_000 ? Double(seconds) / 1000 : Double(seconds)
            return Date(timeIntervalSince1970: epoch)
        }
        if let ms = (params?["_meta"] as? [String: Any])?["agentTimestampMs"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return Date()
    }

    private static func grokText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        if let object = content as? [String: Any] {
            return object["text"] as? String
        }
        return plainText(from: content)
    }

    private static func grokToolPath(_ input: [String: Any]) -> String? {
        (input["target_file"] as? String)
            ?? (input["file_path"] as? String)
            ?? (input["path"] as? String)
    }

    // MARK: - Cursor CLI / ACP stores (SQLite)

    /// Interactive `agent` writes `~/.cursor/chats/<hash>/<id>/store.db`.
    /// ACP mode (`agent acp`, used by Zed, JetBrains, Neovim, T3, custom
    /// clients) writes the same shape under `~/.cursor/acp-sessions/<id>/`.
    private static func cursorStoreRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".cursor/acp-sessions", isDirectory: true),
            home.appendingPathComponent(".cursor/chats", isDirectory: true),
            home.appendingPathComponent(".config/cursor/chats", isDirectory: true),
        ]
    }

    private static func cursorStoreDirectories(in roots: [URL]? = nil) -> [URL] {
        let cutoff = Date().addingTimeInterval(-recentCutoff)
        var found: [(Date, URL)] = []

        for root in roots ?? cursorStoreRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                let store = url.appendingPathComponent("store.db")
                let meta = url.appendingPathComponent("meta.json")
                guard FileManager.default.fileExists(atPath: store.path)
                    || FileManager.default.fileExists(atPath: meta.path)
                else { continue }
                let modified = newestModification(
                    of: cursorStoreWatchFiles(in: url)
                ) ?? Date.distantPast
                guard modified > cutoff else { continue }
                found.append((modified, url))
            }
        }

        found.sort { $0.0 > $1.0 }
        return found.prefix(maxSessions).map(\.1)
    }

    private static func cursorStoreDirectory(for sessionID: String) -> URL? {
        for root in cursorStoreRoots() {
            let direct = root.appendingPathComponent(sessionID, isDirectory: true)
            if FileManager.default.fileExists(atPath: direct.appendingPathComponent("store.db").path)
                || FileManager.default.fileExists(atPath: direct.appendingPathComponent("meta.json").path) {
                return direct
            }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                let nested = child.appendingPathComponent(sessionID, isDirectory: true)
                if FileManager.default.fileExists(atPath: nested.appendingPathComponent("store.db").path)
                    || FileManager.default.fileExists(atPath: nested.appendingPathComponent("meta.json").path) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func cursorStoreWatchFiles(in directory: URL) -> [URL] {
        let store = directory.appendingPathComponent("store.db")
        return [
            directory.appendingPathComponent("meta.json"),
            store,
            URL(fileURLWithPath: store.path + "-wal"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func cursorStoreSessions(directories: [URL]) -> [AgentSession] {
        let t3Runtime = AgentT3RuntimeIndex.index()
        return directories.compactMap {
            parseCursorStore(at: $0, fullHistory: false, t3Runtime: t3Runtime)
        }
    }

    /// Reads one Cursor CLI/ACP session directory (`meta.json` + `store.db`).
    ///
    /// `fullHistory` only changes how large image-bearing JSON blobs are
    /// handled. Prompt, tools, model, and start time come from the small JSON
    /// rows either way — skipping that walk is why Cursor rows used to open
    /// empty while Codex and Claude did not.
    static func parseCursorStore(
        at directory: URL,
        fullHistory: Bool = true,
        sessionID: String? = nil,
        t3Runtime: AgentT3RuntimeIndex = AgentT3RuntimeIndex.index()
    ) -> AgentSession? {

        let folder = directory.pathExtension == "db" ? directory.deletingLastPathComponent() : directory
        let storeURL = folder.appendingPathComponent("store.db")
        let metaURL = folder.appendingPathComponent("meta.json")
        let id = sessionID ?? folder.lastPathComponent
        let modified = newestModification(of: cursorStoreWatchFiles(in: folder)) ?? Date()

        var session = AgentSession(
            id: id,
            provider: .cursor,
            projectName: folder.lastPathComponent,
            lastActivityAt: modified
        )

        if let meta = jsonObjectFromFile(metaURL) {
            session.offer(meta["title"] as? String, from: .client)
            if let cwd = meta["cwd"] as? String, !cwd.isEmpty {
                session.workingDirectory = cwd
                session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
            }
        }

        if isCursorACPDirectory(folder), t3Runtime.exactEntry(sessionID: id) == nil {
            // Transcript modification alone cannot prove an ACP session is open.
            session.finishedAt = .distantPast
            session.isOpenInClient = false
            session.isActive = false
        } else if isCursorACPDirectory(folder), let runtime = t3Runtime.exactEntry(sessionID: id) {
            session.lastActivityAt = runtime.lastEventAt ?? .distantPast
            session.finishedAt = runtime.isWorking ? nil : runtime.lastEventAt ?? modified
            // T3 can keep its reusable provider process alive while no turn is
            // running. Let active/finished state drive live visibility.
            session.isOpenInClient = nil
            session.isActive = runtime.isWorking
        }

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            // cwd alone is not a session. T3, Zed, and other ACP hosts write a
            // meta stub for every connect, usually pointed at $HOME.
            return session.title != nil ? session : nil
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? Int64) ?? 0
        applyCursorStoreMeta(at: storeURL, to: &session)
        if size <= fullReadCeiling {
            applyCursorStore(at: storeURL, fullHistory: fullHistory, to: &session)
            session.lastAgentMessage = session.lastAgentMessage.flatMap {
                AgentSessionPromptSummary.agentExcerpt($0)
            }
        }
        if session.gitBranch == nil {
            session.gitBranch = gitBranch(at: session.workingDirectory)
        }
        if session.model == nil {
            session.model = CursorConversationModels.model(for: session.id)
        }
        if let runtime = t3Runtime.exactEntry(sessionID: id) {
            if let model = runtime.model { session.model = model }
            // The host's sidebar name is what the user recognises. Offered
            // last so Cursor's own name for the same conversation cannot
            // outrank it at equal priority.
            session.offer(runtime.title, from: .client)
        }
        if session.contextWindow == nil {
            session.contextWindow = AgentSession.inferredContextWindow(for: session.model)
        }
        return session.hasVisibleWork ? session : nil
    }

    private static func isCursorACPDirectory(_ directory: URL) -> Bool {
        let components = directory.standardizedFileURL.pathComponents
        return zip(components, components.dropFirst()).contains { parent, child in
            parent == ".cursor" && child == "acp-sessions"
        }
    }

    private static func applyCursorStoreMeta(at storeURL: URL, to session: inout AgentSession) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            storeURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        applyCursorStoreMeta(db: db, to: &session)
    }

    private static func applyCursorStoreMeta(db: OpaquePointer, to session: inout AgentSession) {
        guard let raw = sqliteText(db, "SELECT value FROM meta LIMIT 1"),
              let meta = decodeCursorStoreMeta(raw)
        else { return }
        if let model = (meta["lastUsedModel"] as? String) ?? (meta["model"] as? String) {
            session.model = model
        }
        if let name = meta["name"] as? String {
            session.offer(name, from: .client)
        }
        if session.startedAt == nil {
            let created = int(meta["createdAt"])
            if created > 0 {
                session.startedAt = Date(timeIntervalSince1970: TimeInterval(created) / 1000)
            }
        }
    }

    /// Skip protobuf tree nodes, PNGs, and file contents. JSON messages
    /// start with `{` whether SQLite stored them as TEXT or BLOB.
    private static let cursorListBlobCeiling = 256_000
    private static let cursorFullBlobCeiling = 1_000_000

    private static func applyCursorStore(
        at storeURL: URL,
        fullHistory: Bool,
        to session: inout AgentSession
    ) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            storeURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        applyCursorStoreMeta(db: db, to: &session)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM blobs", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return }
        defer { sqlite3_finalize(statement) }

        let ceiling = fullHistory ? cursorFullBlobCeiling : cursorListBlobCeiling
        var activity: [AgentActivityEntry] = []
        var focus: [String: Double] = [:]
        var index = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqliteBlob(statement, 0), bytes.first == 0x7B else { continue }
            if bytes.count > ceiling {
                if let prompt = cursorStoreUserQuery(in: bytes) {
                    session.lastUserPrompt = firstLine(prompt)
                }
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { continue }
            index += 1
            applyCursorStoreBlob(
                object,
                at: session.lastActivityAt,
                recency: 0.5 + Double(index) / 400,
                session: &session,
                activity: &activity,
                focus: &focus
            )
        }

        if !activity.isEmpty {
            session.recentActivity = Array(collapseRepeats(activity).suffix(activityTail))
        }
        if !focus.isEmpty {
            session.focusScores = Dictionary(
                uniqueKeysWithValues: focus.sorted { $0.value > $1.value }.prefix(5)
                    .map { ($0.key, $0.value) }
            )
        }
        session.offer(agentPhrase(session), from: .agentPhrase)
    }

    private static func applyCursorStoreBlob(
        _ object: [String: Any],
        at: Date,
        recency: Double,
        session: inout AgentSession,
        activity: inout [AgentActivityEntry],
        focus: inout [String: Double]
    ) {
        let role = object["role"] as? String
        let content = object["content"]

        if role == "system", session.model == nil,
           let text = content as? String,
           let model = cursorStoreModel(fromSystem: text) {
            session.model = model
        }

        if role == "user", let prompt = cursorStorePrompt(from: content) {
            session.lastUserPrompt = firstLine(prompt)
        }
        if role == "assistant", let text = cursorStoreText(from: content), !text.isEmpty {
            // Excerpted once in `parseCursorStore` after every row is read.
            session.lastAgentMessage = text
        }

        let blocks: [[String: Any]]
        if let list = content as? [[String: Any]] {
            blocks = list
        } else {
            blocks = []
        }

        for block in blocks {
            guard (block["type"] as? String) == "tool-call",
                  let name = block["toolName"] as? String
            else { continue }
            var input = (block["args"] as? [String: Any]) ?? [:]
            if input["file_path"] == nil, let path = input["path"] as? String {
                input["file_path"] = path
            }
            if input["pattern"] == nil, let glob = input["glob_pattern"] as? String {
                input["pattern"] = glob
            }
            let described = AgentToolLabel.describe(tool: name, input: input)
            activity.append(AgentActivityEntry(
                kind: described.kind,
                detail: described.detail,
                target: described.target,
                at: at
            ))
            session.currentActivity = described.detail
            if let path = input["file_path"] as? String {
                let file = URL(fileURLWithPath: path).lastPathComponent
                let weight: Double = described.kind == .edit ? 4 : 1
                focus[file, default: 0] += weight * recency
            }
        }
    }

    /// Cursor wraps the typed question in `<user_query>`. The rest of the
    /// blob is harness chrome (`<timestamp>`, screenshots) and must not become
    /// the line on the island.
    private static func cursorStorePrompt(from content: Any?) -> String? {
        guard let text = cursorStoreText(from: content) else { return nil }
        if let query = taggedText(text, tag: "user_query") { return query }
        return isSynthetic(text) ? nil : text
    }

    private static func cursorStoreText(from content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String,
                  !text.isEmpty
            else { continue }
            return text
        }
        return nil
    }

    private static func cursorStoreUserQuery(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return taggedText(text, tag: "user_query")
    }

    private static func taggedText(_ text: String, tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex)
        else { return nil }
        let body = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// `You are an AI coding assistant, powered by Cursor Grok 4.6.`
    private static func cursorStoreModel(fromSystem text: String) -> String? {
        guard let start = text.range(of: "powered by ") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: ". ")?.lowerBound
            ?? rest.firstIndex(where: \.isNewline)
            ?? rest.endIndex
        var model = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        if model.lowercased().hasPrefix("cursor ") {
            model = String(model.dropFirst("cursor ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return model.isEmpty ? nil : model
    }

    private static func decodeCursorStoreMeta(_ raw: String) -> [String: Any]? {
        if let object = jsonObject(raw) { return object }
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jsonObjectFromFile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func newestModification(of urls: [URL]) -> Date? {
        urls.compactMap { modificationDate(of: $0) }.max()
    }

    private static func sqliteText(_ db: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static func sqliteBlob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// The same session can appear as an IDE jsonl and as a CLI/ACP store.
    /// Keep one row and take the stronger fields from both.
    private static func mergeSessionsByID(_ sessions: [AgentSession]) -> [AgentSession] {
        var merged: [String: AgentSession] = [:]
        for session in sessions {
            if let existing = merged[session.id] {
                merged[session.id] = combine(existing, session)
            } else {
                merged[session.id] = session
            }
        }
        return Array(merged.values)
    }

    static func combine(_ lhs: AgentSession, _ rhs: AgentSession) -> AgentSession {
        var winner = lhs.lastActivityAt >= rhs.lastActivityAt ? lhs : rhs
        let other = lhs.lastActivityAt >= rhs.lastActivityAt ? rhs : lhs
        if let title = other.title {
            winner.offer(title.text, from: title.source)
        }
        if winner.lastUserPrompt == nil { winner.lastUserPrompt = other.lastUserPrompt }
        if let started = other.turnStartedAt, started > winner.turnStartedAt ?? .distantPast {
            winner.turnStartedAt = started
        }
        if winner.lastAgentMessage == nil { winner.lastAgentMessage = other.lastAgentMessage }
        if winner.workingDirectory == nil {
            winner.workingDirectory = other.workingDirectory
            if winner.projectName == winner.id || winner.projectName == "Session" {
                winner.projectName = other.projectName
            }
        }
        if winner.model == nil { winner.model = other.model }
        // A transcript rescan knows the entrypoint; hooks know the exact app.
        // Neither should erase what the other established.
        if winner.host == nil { winner.host = other.host }
        if winner.hostBundleID == nil { winner.hostBundleID = other.hostBundleID }
        if winner.gitBranch == nil { winner.gitBranch = other.gitBranch }
        if winner.startedAt == nil { winner.startedAt = other.startedAt }
        if winner.contextWindow == nil { winner.contextWindow = other.contextWindow }
        if winner.contextUsed == nil { winner.contextUsed = other.contextUsed }
        if let contextFraction = rhs.contextFractionOverride {
            winner.contextFractionOverride = contextFraction
        }
        if let isOpenInClient = rhs.isOpenInClient {
            winner.isOpenInClient = isOpenInClient
            if isOpenInClient {
                winner.finishedAt = nil
            } else {
                winner.finishedAt = winner.finishedAt ?? winner.lastActivityAt
                winner.isActive = false
            }
        }
        if winner.recentActivity.isEmpty { winner.recentActivity = other.recentActivity }
        if winner.currentActivity == nil { winner.currentActivity = other.currentActivity }
        if winner.todos.isEmpty { winner.todos = other.todos }
        if winner.plan == nil { winner.plan = other.plan }
        winner.subagents = mergeSubagents(lhs.subagents, rhs.subagents)
        winner.linesAdded = max(lhs.linesAdded, rhs.linesAdded)
        winner.linesRemoved = max(lhs.linesRemoved, rhs.linesRemoved)
        winner.changedFiles = AgentFileChange.union(other.changedFiles, winner.changedFiles)
        if winner.conversation.isEmpty { winner.conversation = other.conversation }
        if winner.focusScores.isEmpty { winner.focusScores = other.focusScores }
        return winner
    }

    /// Keeps the full-history order and multiplicity without duplicating the
    /// same parsed runs every time a lightweight tail snapshot arrives.
    private static func mergeSubagents(
        _ lhs: [AgentSubagent],
        _ rhs: [AgentSubagent]
    ) -> [AgentSubagent] {
        let base = lhs.count >= rhs.count ? lhs : rhs
        let additions = lhs.count >= rhs.count ? rhs : lhs
        var merged = base
        var existingCounts: [String: Int] = [:]
        for agent in base {
            existingCounts["\(agent.type)\u{0}\(agent.task)", default: 0] += 1
        }

        var seenInAdditions: [String: Int] = [:]
        for agent in additions {
            let key = "\(agent.type)\u{0}\(agent.task)"
            seenInAdditions[key, default: 0] += 1
            if seenInAdditions[key, default: 0] > existingCounts[key, default: 0] {
                merged.append(agent)
            }
        }
        return merged
    }

    // MARK: - OpenCode (SQLite)

    /// opencode keeps sessions in one SQLite database rather than transcript
    /// files, so discovery is a query instead of a directory walk. Rows are
    /// attributed to the vendor behind the session (Kimi, Moonshot, ...),
    /// falling back to opencode itself when the vendor is one Nano does not
    /// know.
    private static func openCodeSessions(databaseURL: URL? = nil) -> [AgentSession] {
        guard let dbPath = databaseURL ?? openCodeDatabaseURL() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_close(db) }

        let cutoffMs = Int64(Date().addingTimeInterval(-recentCutoff).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT id, title, directory, model, summary_additions, summary_deletions,
               time_created, time_updated
        FROM session
        WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated > ?
        ORDER BY time_updated DESC
        LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoffMs)

        var sessions: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let title = sqlite3_column_text(statement, 1).map(String.init(cString:))
            let directory = sqlite3_column_text(statement, 2).map(String.init(cString:))
            let modelJSON = sqlite3_column_text(statement, 3).map(String.init(cString:))
            let additions = sqlite3_column_int64(statement, 4)
            let deletions = sqlite3_column_int64(statement, 5)
            let createdMs = sqlite3_column_int64(statement, 6)
            let updatedMs = sqlite3_column_int64(statement, 7)

            var providerID: String?
            var modelID: String?
            if let modelJSON,
               let object = try? JSONSerialization.jsonObject(with: Data(modelJSON.utf8)) as? [String: Any] {
                providerID = object["providerID"] as? String
                modelID = object["id"] as? String
            }

            var session = AgentSession(
                id: String(cString: idText),
                provider: AgentProviderID.normalize(providerID)
                    .flatMap(AgentProviderID.init(rawValue:)) ?? .opencode,
                projectName: directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session",
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000)
            )
            // opencode keeps its own title on the session row.
            session.offer(title, from: .client)
            session.workingDirectory = directory
            session.model = modelID
            session.startedAt = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000)
            session.linesAdded = Int(additions)
            session.linesRemoved = Int(deletions)
            sessions.append(session)
        }
        return sessions
    }

    /// Loads the rich half of an OpenCode session on demand. The list query
    /// intentionally stays tiny; prompts and tool parts are only read for the
    /// row the user opens.
    private static func openCodeSessionDetail(
        sessionID: String,
        databaseURL: URL? = nil
    ) -> AgentSession? {
        guard let dbPath = databaseURL ?? openCodeDatabaseURL() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        guard var session = openCodeSessions(databaseURL: dbPath).first(where: { $0.id == sessionID }) else {
            return nil
        }

        let sql = """
        SELECT recent.part_data, recent.message_data, recent.time_created
        FROM (
            SELECT p.data AS part_data, m.data AS message_data,
                   p.time_created AS time_created
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ?
            ORDER BY p.time_created DESC
            LIMIT 400
        ) AS recent
        ORDER BY recent.time_created ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return session
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(
            statement, 1, sessionID, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )

        var activity: [AgentActivityEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let partText = sqlite3_column_text(statement, 0),
                  let messageText = sqlite3_column_text(statement, 1),
                  let part = jsonObject(String(cString: partText)),
                  let message = jsonObject(String(cString: messageText))
            else { continue }
            let at = Date(timeIntervalSince1970:
                TimeInterval(sqlite3_column_int64(statement, 2)) / 1000)

            if let model = message["modelID"] as? String { session.model = model }
            switch part["type"] as? String {
            case "text":
                if (message["role"] as? String) == "user",
                   (part["synthetic"] as? Bool) != true,
                   let text = part["text"] as? String,
                   !text.isEmpty, !isSynthetic(text) {
                    session.lastUserPrompt = firstLine(text)
                }
            case "tool":
                guard let tool = part["tool"] as? String else { continue }
                let state = part["state"] as? [String: Any] ?? [:]
                let input = state["input"] as? [String: Any] ?? [:]
                let described = AgentToolLabel.describe(tool: tool, input: input)
                activity.append(AgentActivityEntry(
                    kind: described.kind,
                    detail: described.detail,
                    target: described.target,
                    at: at
                ))
                session.currentActivity = described.detail
            default:
                break
            }
        }
        session.recentActivity = Array(collapseRepeats(activity).suffix(activityTail))

        let todoSQL = """
        SELECT content, status FROM todo
        WHERE session_id = ? ORDER BY position ASC
        """
        var todoStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, todoSQL, -1, &todoStatement, nil) == SQLITE_OK,
           let todoStatement {
            defer { sqlite3_finalize(todoStatement) }
            sqlite3_bind_text(
                todoStatement, 1, sessionID, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            while sqlite3_step(todoStatement) == SQLITE_ROW {
                guard let content = sqlite3_column_text(todoStatement, 0) else { continue }
                let status = sqlite3_column_text(todoStatement, 1).map(String.init(cString:))
                session.todos.append((String(cString: content), status == "completed"))
            }
        }
        return session
    }

    static func parseOpenCodeSession(at databaseURL: URL, sessionID: String) -> AgentSession? {
        openCodeSessionDetail(sessionID: sessionID, databaseURL: databaseURL)
    }

    // MARK: - Devin (SQLite)

    /// Devin loads hooks once at `session/new`, so sessions older than the
    /// hook installation never report to the bridge at all. Its session store
    /// is the discovery path that covers them. Rows still merge with hook
    /// state by id when hooks do fire — the hook's `session_id` is this
    /// table's `id`.
    static func devinSessions(databaseURL: URL? = nil) -> [AgentSession] {
        let cutoff = Int(Date().addingTimeInterval(-recentCutoff).timeIntervalSince1970)
        return AgentDevinSessionMetadata.index(
            databaseURL: databaseURL, since: cutoff, limit: 20
        ).map { id, entry in
            var session = AgentSession(
                id: id,
                provider: .devin,
                projectName: entry.workingDirectory
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session",
                lastActivityAt: entry.lastActivityAt ?? entry.createdAt ?? .distantPast
            )
            // Devin's own title beats the first prompt Nano would otherwise show.
            session.offer(entry.title, from: .client)
            session.workingDirectory = entry.workingDirectory
            session.model = entry.model
            session.startedAt = entry.createdAt
            // sessions.db covers the CLI too, but Devin Desktop is the far
            // common case and a running hook event still overrides this host.
            session.host = .app
            session.hostBundleID = "com.exafunction.windsurf"
            return session
        }
    }

    // MARK: - Disk-backed stores shared by the CLI providers

    /// Read-only open for a live SQLite store: a `-wal` sibling means normal
    /// read-only open sees current rows; without it the immutable URI view of
    /// the last checkpoint is the only open that succeeds.
    private static func openReadOnlyDatabase(_ url: URL) -> OpaquePointer? {
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let hasWAL = FileManager.default.fileExists(atPath: walURL.path)
        let location = hasWAL ? url.path : url.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (hasWAL ? 0 : SQLITE_OPEN_URI)
        var db: OpaquePointer?
        guard sqlite3_open_v2(location, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        sqlite3_busy_timeout(db, 100)
        return db
    }

    /// Upstream schemas drift between releases, so queries are built from the
    /// columns that actually exist rather than a fixed SELECT.
    private static func sqliteColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
        guard sqlite3_prepare_v2(
            db, "PRAGMA table_info(\"\(escaped)\")", -1, &statement, nil
        ) == SQLITE_OK, let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private static func sqliteColumnText(_ statement: OpaquePointer, _ index: Int32?) -> String? {
        guard let index, let text = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The stores differ on time format: Cline writes ISO 8601, Goose writes
    /// `YYYY-MM-DD HH:MM:SS` UTC or a bare epoch, and some builds mix them.
    static func flexibleDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = date(fromISO: text) { return date }
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            utc.dateFormat = format
            if let date = utc.date(from: text) { return date }
        }
        if let epoch = Double(text), epoch > 0 {
            return Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000 : epoch)
        }
        return nil
    }

    private static func watchBase(for url: URL) -> URL {
        url.lastPathComponent.hasSuffix("-wal")
            ? URL(fileURLWithPath: String(url.path.dropLast(4)))
            : url
    }

    // MARK: - Cline (SQLite)

    /// Cline CLI keeps sessions in a `sessions` table much like Devin's. Both
    /// documented layouts are read: `<data>/db/sessions.db` and the
    /// `<data>/sessions/sessions.db` some builds use. `ended_at` is a real
    /// lifecycle signal, so finished rows carry `finishedAt` rather than
    /// relying on the quiet-transcript heuristic.
    static func clineSessions(
        directories: (data: URL, database: URL, sessions: URL)? = nil
    ) -> [AgentSession] {
        let dirs = directories ?? TokenScanners.clineDirectories()
        let stores = [dirs.database, dirs.sessions
            .appendingPathComponent("sessions.db")]
        return mergeSessionsByID(
            stores
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .flatMap { clineSessionsIn(databaseURL: $0) }
        ).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private static func clineDatabaseFiles(
        directories: (data: URL, database: URL, sessions: URL)
    ) -> [URL] {
        let stores = [directories.database, directories.sessions
            .appendingPathComponent("sessions.db")]
        return stores.flatMap { store in
            [store, URL(fileURLWithPath: store.path + "-wal")]
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func clineSessionsIn(databaseURL: URL) -> [AgentSession] {
        guard let db = openReadOnlyDatabase(databaseURL) else { return [] }
        defer { sqlite3_close(db) }

        let columns = sqliteColumns(db, table: "sessions")
        guard columns.contains("session_id"), columns.contains("updated_at") else { return [] }
        let wanted = ["session_id", "updated_at", "started_at", "ended_at",
                      "cwd", "workspace_root", "model", "prompt"]
        let selected = wanted.filter { columns.contains($0) }
        var predicates = ["updated_at IS NOT NULL"]
        if columns.contains("is_subagent") {
            predicates.append("COALESCE(is_subagent, 0) = 0")
        }
        if columns.contains("parent_session_id") {
            predicates.append("parent_session_id IS NULL")
        }
        let sql = """
        SELECT \(selected.joined(separator: ", "))
        FROM sessions
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY updated_at DESC
        LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        let index = Dictionary(
            uniqueKeysWithValues: selected.enumerated().map { ($0.element, Int32($0.offset)) }
        )
        func text(_ name: String) -> String? { sqliteColumnText(statement, index[name]) }
        func date(_ name: String) -> Date? { flexibleDate(text(name)) }

        // `updated_at` is ISO text, so the recency filter runs on parsed
        // dates rather than in SQL where formats could compare wrongly.
        let cutoff = Date().addingTimeInterval(-recentCutoff)
        var sessions: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW, sessions.count < 20 {
            guard let id = text("session_id"),
                  let updated = date("updated_at"), updated > cutoff
            else { continue }
            let directory = text("cwd") ?? text("workspace_root")
            var session = AgentSession(
                id: id,
                provider: .cline,
                projectName: directory
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session",
                lastActivityAt: updated
            )
            session.workingDirectory = directory
            session.model = text("model")
            session.startedAt = date("started_at")
            session.finishedAt = date("ended_at")
            if let prompt = text("prompt") {
                session.lastUserPrompt = firstLine(prompt)
            }
            sessions.append(session)
        }
        return sessions
    }

    // MARK: - Kilo Code (SQLite)

    /// Kilo's CLI is an OpenCode fork, so the `session` table follows the same
    /// shape: epoch-millisecond timestamps, `parent_id` for subagents and
    /// `time_archived` for rows Kilo hides itself.
    static func kiloSessions(databaseURL: URL? = nil) -> [AgentSession] {
        let url = databaseURL ?? TokenScanners.kiloDatabaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return kiloSessionsIn(databaseURL: url)
    }

    static func kiloSessionsIn(databaseURL: URL) -> [AgentSession] {
        guard let db = openReadOnlyDatabase(databaseURL) else { return [] }
        defer { sqlite3_close(db) }

        let columns = sqliteColumns(db, table: "session")
        guard columns.contains("id"), columns.contains("time_updated") else { return [] }
        let wanted = ["id", "time_updated", "time_created", "title", "directory", "model"]
        let selected = wanted.filter { columns.contains($0) }
        let cutoffMs = Int64(Date().addingTimeInterval(-recentCutoff).timeIntervalSince1970 * 1000)
        var predicates = ["time_updated > \(cutoffMs)"]
        if columns.contains("parent_id") {
            predicates.append("parent_id IS NULL")
        }
        if columns.contains("time_archived") {
            predicates.append("time_archived IS NULL")
        }
        let sql = """
        SELECT \(selected.joined(separator: ", "))
        FROM session
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY time_updated DESC
        LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        let index = Dictionary(
            uniqueKeysWithValues: selected.enumerated().map { ($0.element, Int32($0.offset)) }
        )
        func text(_ name: String) -> String? { sqliteColumnText(statement, index[name]) }
        func ms(_ name: String) -> Date? {
            index[name].map { sqlite3_column_int64(statement, $0) }
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil }
        }

        var sessions: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text("id"), let updated = ms("time_updated") else { continue }
            let directory = text("directory")
            var session = AgentSession(
                id: id,
                provider: .kilo,
                projectName: directory
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session",
                lastActivityAt: updated
            )
            session.offer(text("title"), from: .client)
            session.workingDirectory = directory
            session.model = text("model")
            session.startedAt = ms("time_created")
            sessions.append(session)
        }
        return sessions
    }

    // MARK: - Goose (SQLite)

    /// Goose stores sessions under its data dir's `sessions/sessions.db`;
    /// every existing database location is read, since installs drifted from
    /// `~/Library/Application Support/Block/goose` to the XDG path over time.
    static func gooseSessions(databaseURLs: [URL]? = nil) -> [AgentSession] {
        let urls = (databaseURLs ?? TokenScanners.gooseDatabaseURLs())
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return mergeSessionsByID(
            urls.flatMap { gooseSessionsIn(databaseURL: $0) }
        ).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    static func gooseSessionsIn(databaseURL: URL) -> [AgentSession] {
        guard let db = openReadOnlyDatabase(databaseURL) else { return [] }
        defer { sqlite3_close(db) }

        let columns = sqliteColumns(db, table: "sessions")
        guard columns.contains("id"), columns.contains("updated_at") else { return [] }
        let wanted = ["id", "updated_at", "created_at", "working_dir",
                      "name", "description", "user_set_name", "model_config",
                      "model_config_json", "provider_name"]
        let selected = wanted.filter { columns.contains($0) }
        var predicates = ["updated_at IS NOT NULL"]
        if columns.contains("session_type") {
            predicates.append("session_type = 'user'")
        }
        if columns.contains("archived_at") {
            predicates.append("archived_at IS NULL")
        }
        let sql = """
        SELECT \(selected.joined(separator: ", "))
        FROM sessions
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY updated_at DESC
        LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        let index = Dictionary(
            uniqueKeysWithValues: selected.enumerated().map { ($0.element, Int32($0.offset)) }
        )
        func text(_ name: String) -> String? { sqliteColumnText(statement, index[name]) }
        func date(_ name: String) -> Date? { flexibleDate(text(name)) }

        let cutoff = Date().addingTimeInterval(-recentCutoff)
        var sessions: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW, sessions.count < 20 {
            guard let id = text("id"),
                  let updated = date("updated_at"), updated > cutoff
            else { continue }
            let directory = text("working_dir")
            var session = AgentSession(
                id: id,
                provider: .goose,
                projectName: directory
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session",
                lastActivityAt: updated
            )
            // `name` replaced `description` at schema v3; whichever exists wins.
            let userNamed = index["user_set_name"]
                .map { sqlite3_column_int64(statement, $0) == 1 } ?? false
            session.offer(text("name") ?? text("description"),
                          from: userNamed ? .userNamed : .client)
            session.workingDirectory = directory
            session.startedAt = date("created_at")
            if let configJSON = text("model_config") ?? text("model_config_json"),
               let config = jsonObject(configJSON) {
                session.model = config["model_name"] as? String
            }
            sessions.append(session)
        }
        return sessions
    }

    // MARK: - Qwen Code (JSONL chats)

    /// Qwen has no session database: each chat is a JSONL file under
    /// `<runtime>/projects/<encoded-path>/chats`. Stat-only discovery keeps
    /// the scan cheap; only the newest twenty files are read.
    static func qwenSessions(roots: [URL]? = nil) -> [AgentSession] {
        qwenSessionFiles(roots: roots).compactMap {
            qwenSession(file: $0.url, modified: $0.modified, size: $0.size)
        }
    }

    private static func qwenSessionFiles(
        roots: [URL]? = nil
    ) -> [(url: URL, modified: Date, size: Int64)] {
        let runtimeRoots = roots ?? [TokenScanners.qwenRuntimeDirectory()]
        let cutoff = Date().addingTimeInterval(-recentCutoff)
        var files: [(url: URL, modified: Date, size: Int64)] = []
        for root in runtimeRoots {
            let projects = root.appendingPathComponent("projects", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: projects,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                guard file.pathExtension == "jsonl",
                      file.deletingLastPathComponent().lastPathComponent == "chats",
                      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified > cutoff
                else { continue }
                files.append((file, modified, (attributes[.size] as? Int64) ?? 0))
            }
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(20))
    }

    private static func qwenSession(
        file: URL,
        modified providedModified: Date? = nil,
        size providedSize: Int64? = nil
    ) -> AgentSession? {
        let attributes = providedModified == nil || providedSize == nil
            ? try? FileManager.default.attributesOfItem(atPath: file.path)
            : nil
        guard let modified = providedModified ?? attributes?[.modificationDate] as? Date
        else { return nil }
        let size = providedSize ?? (attributes?[.size] as? Int64) ?? 0

        func recordText(_ object: [String: Any]) -> String? {
            let container = (object["message"] as? [String: Any]) ?? object
            let parts = container["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }

        // The head holds the session header (`workspaceRootPath`) and the
        // first prompt; both are early enough that a 64KB read always sees them.
        var sessionID: String?
        var workspace: String?
        var headerName: String?
        var firstPrompt: String?
        var startedAt: Date?
        for line in head(of: file).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = json(from: line) else { continue }
            sessionID = sessionID
                ?? (object["sessionId"] as? String) ?? (object["id"] as? String)
            workspace = workspace ?? object["workspaceRootPath"] as? String
            headerName = headerName ?? object["name"] as? String
            startedAt = startedAt
                ?? (object["timestamp"] as? String).flatMap(flexibleDate)
            guard firstPrompt == nil,
                  (object["type"] as? String) == "user",
                  (object["subtype"] as? String) == nil,
                  let text = recordText(object)
            else { continue }
            firstPrompt = firstLine(text)
        }

        // The tail holds the freshest record fields; the newest `custom_title`
        // record is the name a `/rename` wrote most recently.
        var lastActivity: Date?
        var cwd: String?
        var model: String?
        var customTitle: String?
        if let tailText = tail(of: file, size: size, bytes: tailBytes) {
            for line in tailText.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let object = json(from: line) else { continue }
                if (object["subtype"] as? String) == "ui_telemetry" { continue }
                if customTitle == nil, (object["subtype"] as? String) == "custom_title" {
                    customTitle = recordText(object) ?? object["title"] as? String
                }
                if lastActivity == nil {
                    lastActivity = (object["timestamp"] as? String).flatMap(flexibleDate)
                }
                cwd = cwd ?? object["cwd"] as? String
                model = model ?? object["model"] as? String
                if lastActivity != nil, cwd != nil, model != nil, customTitle != nil { break }
            }
        }

        let directory = cwd ?? workspace
        var session = AgentSession(
            id: sessionID ?? file.deletingPathExtension().lastPathComponent,
            provider: .qwen,
            projectName: directory
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session",
            lastActivityAt: lastActivity ?? modified
        )
        session.workingDirectory = directory
        session.model = model
        session.startedAt = startedAt
        if let customTitle {
            session.offer(customTitle, from: .userNamed)
        } else {
            session.offer(headerName, from: .client)
            session.lastUserPrompt = firstPrompt
        }
        return session
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func openCodeDataDirectoryURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    private static func openCodeDatabaseURL() -> URL? {
        let url = openCodeDataDirectoryURL().appendingPathComponent("opencode.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Parsing

    /// Full-file totals for one session, read on demand.
    ///
    /// The list scan reads a 256KB tail so it stays cheap on a 20MB transcript.
    /// That is right for "what is it doing now" but wrong for the cumulative
    /// fields: lines changed and subagents are session totals, and a tail
    /// showed a few minutes of them. This re-reads one file, only when the user
    /// opens it, and only when it is small enough to be worth reading.
    static func parseFull(sessionID: String) -> AgentSession? {
        var candidates = claudeCandidates() + codexCandidates() + cursorCandidates()
            + piCandidates()
        candidates.sort { $0.modified > $1.modified }
        if let candidate = candidates.first(where: {
            let stem = $0.url.deletingPathExtension().lastPathComponent
            return stem == sessionID
                || ($0.provider == .codex && stem.hasSuffix("-\(sessionID)"))
        }) {
            guard candidate.size <= fullReadCeiling else { return nil }
            return parse(
                candidate,
                known: AgentKnownTitles.read(since: Date().addingTimeInterval(-recentCutoff)),
                fullHistory: true
            )
        }
        if let store = cursorStoreDirectory(for: sessionID) {
            return parseCursorStore(at: store, fullHistory: true, sessionID: sessionID)
        }
        if let directory = grokSessionDirectories(sessionID: sessionID).first {
            return parseGrokSession(
                at: directory,
                known: AgentKnownTitles.read(since: Date().addingTimeInterval(-recentCutoff)),
                fullHistory: true
            )
        }
        return openCodeSessionDetail(sessionID: sessionID)
    }

    /// Parses a known transcript path. Besides keeping tests deterministic,
    /// this is the path hook integrations can use when an agent supplies a
    /// transcript outside Nano's standard discovery roots.
    static func parseTranscript(
        at url: URL,
        provider: AgentProviderID,
        projectDirectory: String? = nil,
        codexThreadNames: [String: String] = [:],
        cursorMetadata: [String: AgentCursorConversationMetadata.Entry] = [:]
    ) -> AgentSession? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        let candidate = Candidate(
            url: url,
            provider: provider,
            modified: (attributes[.modificationDate] as? Date) ?? Date(),
            size: (attributes[.size] as? Int64) ?? 0,
            projectDirectory: projectDirectory
        )
        return parse(
            candidate,
            known: AgentKnownTitles(codex: codexThreadNames, cursor: cursorMetadata),
            fullHistory: true
        )
    }

    private static let fullReadCeiling: Int64 = 64_000_000

    private static func parse(
        _ candidate: Candidate,
        known: AgentKnownTitles,
        fullHistory: Bool = false,
        wideTail: Bool = false
    ) -> AgentSession? {
        // Child-agent rollouts are implementation detail inside their parent
        // session. Codex marks them in session_meta; Claude and Cursor place
        // their child transcripts in a `subagents` directory. Neither belongs
        // in Nano's top-level session list.
        let opening = head(of: candidate.url)
        guard !isSubagentTranscript(candidate, opening: opening) else { return nil }

        // Bytes, not a String: transcripts run to tens of megabytes, and
        // splitting one by Character cost more than parsing its JSON. A full
        // read is mapped so the file is never copied into memory whole.
        let data: Data?
        if fullHistory {
            data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe)
        } else {
            data = tailData(
                of: candidate.url,
                size: candidate.size,
                bytes: wideTail ? wideTailBytes : tailBytes
            )
        }
        guard let data else { return nil }

        // The project path lives in the first line (Codex writes a
        // `session_meta` record), which a tail read never reaches — without
        // this, Codex sessions are named after their date folder.

        var session = AgentSession(
            id: candidate.provider == .codex
                ? (codexSessionID(from: opening)
                    ?? candidate.url.deletingPathExtension().lastPathComponent)
                : candidate.url.deletingPathExtension().lastPathComponent,
            provider: candidate.provider,
            projectName: candidate.projectDirectory.map(readableProjectName)
                ?? candidate.url.deletingLastPathComponent().lastPathComponent,
            lastActivityAt: candidate.modified
        )
        if let directory = candidate.projectDirectory {
            session.workingDirectory = recoverMangledPath(directory) ?? unmangle(directory)
        }

        var codexOriginator: String?
        for line in opening.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = json(from: line) else { continue }
            if session.startedAt == nil {
                session.startedAt = (object["timestamp"] as? String).flatMap(date(fromISO:))
            }
            let payload = (object["payload"] as? [String: Any]) ?? object
            if let cwd = (payload["cwd"] as? String) ?? (object["cwd"] as? String) {
                session.workingDirectory = cwd
                session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
            }
            if candidate.provider == .codex, let originator = payload["originator"] as? String {
                if session.host == nil { session.host = AgentSessionJump.codexHost(originator: originator) }
                codexOriginator = originator
            }
            if let window = (payload["model_context_window"] as? Int)
                ?? (payload["context_window"] as? Int) {
                session.contextWindow = window
            }
        }

        var seen: Set<String> = []
        var activity: [AgentActivityEntry] = []
        var focus: [String: Double] = [:]
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A tail read starts mid-line, and a live session leaves the final one
        // half-written; both simply fail to parse and are skipped. A full read
        // starts at byte 0, where the first line is intact and worth keeping.
        if !fullHistory, !lines.isEmpty { lines.removeFirst() }
        var newestRecordAt: Date?
        var entrypoint: String?
        var latestAgentText: String?
        var turns: [AgentConversationTurn] = []

        for (index, line) in lines.enumerated() {
            // The pool frees each record's Foundation temporaries as it goes;
            // a full read otherwise holds them all until the parse returns.
            guard let object = autoreleasepool(invoking: { json(from: line) }) else { continue }
            let recordAt = (object["timestamp"] as? String).flatMap(date(fromISO:))
            if let recordAt, recordAt > newestRecordAt ?? .distantPast { newestRecordAt = recordAt }
            let at = recordAt ?? candidate.modified
            if let value = object["entrypoint"] as? String, !value.isEmpty { entrypoint = value }

            if candidate.provider == .codex,
               (object["type"] as? String) == "event_msg",
               let event = object["payload"] as? [String: Any],
               let type = event["type"] as? String {
                switch type {
                case "user_message", "task_started":
                    session.finishedAt = nil
                case "task_complete", "task_failed", "task_cancelled", "turn_aborted":
                    session.finishedAt = at
                default:
                    break
                }
            }

            if candidate.provider == .cursor,
               (object["type"] as? String) == "turn_ended" {
                session.finishedAt = at
                continue
            }

            // Sidecar records, not messages: the agent states its own title and
            // last prompt directly, which beats inferring either from content.
            switch object["type"] as? String {
            case "ai-title":
                session.offer(object["aiTitle"] as? String, from: .aiTitle)
                continue
            case "custom-title":
                // Claude `/rename` and the Agent SDK append this record to the
                // transcript. It is the person's chosen name, not an AI title.
                session.offer(object["customTitle"] as? String, from: .userNamed)
                continue
            case "queue-operation":
                // Background subagents report their end here first.
                if let text = object["content"] as? String {
                    AgentSubagent.applyNotifications(in: text, at: at, to: &session.subagents)
                }
                continue
            case "session_info":
                // Pi `/name` stores the display name as a session_info entry.
                session.offer(object["name"] as? String, from: .userNamed)
                continue
            case "last-prompt":
                if let prompt = object["lastPrompt"] as? String,
                   !prompt.isEmpty, !isSynthetic(prompt) {
                    session.lastUserPrompt = firstLine(prompt)
                }
                continue
            default:
                break
            }

            if let cwd = object["cwd"] as? String {
                session.workingDirectory = cwd
                if candidate.provider == .codex {
                    session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
                }
            }
            // "HEAD" is what Claude Code writes when there is no branch to
            // report - a detached checkout, or no repository at all. Showing it
            // puts a label on screen that answers nothing.
            if let branch = object["gitBranch"] as? String,
               !branch.isEmpty, branch != "HEAD", branch != "(no branch)" {
                session.gitBranch = branch
            }
            if let model = object["model"] as? String { session.model = model }

            if candidate.provider == .codex {
                applyCodexRecord(
                    object,
                    at: at,
                    recency: 0.5 + Double(index) / Double(max(lines.count, 1)),
                    session: &session,
                    activity: &activity,
                    focus: &focus,
                    turns: &turns
                )
            }

            if let info = nested(object, "info") {
                if let window = info["model_context_window"] as? Int {
                    session.contextWindow = window
                }
                // Codex's total is cumulative over the whole rollout, not the
                // context currently in the model. Using it made every mature
                // session clamp to 100%. The latest model call is the value
                // comparable to Claude's per-message usage.
                if let usage = (info["last_token_usage"] as? [String: Any])
                    ?? (info["total_token_usage"] as? [String: Any]) {
                    session.contextUsed = int(usage["total_tokens"])
                }
            }

            let payload = (object["message"] as? [String: Any])
                ?? (object["payload"] as? [String: Any])
            guard let payload else { continue }

            // Before the id check: Claude writes one reply as several lines
            // sharing a message id (thinking, text, tool call), and the text
            // is rarely the first of them.
            if ((payload["role"] as? String) ?? (object["role"] as? String)) == "assistant",
               let text = plainText(from: payload["content"]),
               !text.isEmpty {
                // Raw here; excerpted once after the loop. Cleaning every
                // reply in a 256KB tail cost more than the rest of the parse.
                latestAgentText = text
                AgentConversationTurn.note(reply: text, in: &turns)
            }
            if let id = payload["id"] as? String {
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            if let model = payload["model"] as? String, model != "<synthetic>" {
                session.model = model
            }
            if let usage = payload["usage"] as? [String: Any] {
                let used = int(usage["input_tokens"])
                    + int(usage["cache_read_input_tokens"])
                    + int(usage["cache_creation_input_tokens"])
                if used > 0 { session.contextUsed = used }
            }
            let role = (payload["role"] as? String) ?? (object["role"] as? String)
            if role == "user",
               let prompt = plainText(from: payload["content"]),
               !isSynthetic(prompt) {
                session.lastUserPrompt = firstLine(prompt)
                session.turnStartedAt = at
                AgentConversationTurn.note(prompt: prompt, in: &turns)
                if candidate.provider == .cursor { session.finishedAt = nil }
            }
            for entry in activityEntries(from: payload["content"], at: at) {
                activity.append(entry)
                session.currentActivity = entry.detail
                AgentConversationTurn.note(tool: entry.kind, in: &turns)
            }
            // Ramped across the window so where the session is working now
            // outweighs where it started.
            let recency = 0.5 + Double(index) / Double(max(lines.count, 1))
            for (file, weight) in focusWeights(from: payload["content"]) {
                focus[file, default: 0] += weight * recency
            }
            if let todos = todoList(from: payload["content"]) {
                session.todos = todos
            }
            if let plan = planText(from: payload["content"]) {
                session.plan = plan
            }
            session.subagents.append(contentsOf: subagents(from: payload["content"], at: at))
            AgentSubagent.complete(&session.subagents, from: payload["content"], at: at)
            let changes = fileChanges(from: payload["content"])
            session.linesAdded += changes.reduce(0) { $0 + $1.added }
            session.linesRemoved += changes.reduce(0) { $0 + $1.removed }
            AgentFileChange.merging(changes, into: &session.changedFiles)
        }
        session.conversation = AgentConversationTurn.finalized(turns)

        // Claude clients rewrite untimestamped sidecar records (`last-prompt`,
        // `custom-title`) into old transcripts, which bumps the file's mtime
        // with no new conversation. The newest real record is the activity.
        if candidate.provider == .claude, let newestRecordAt, newestRecordAt < candidate.modified {
            session.lastActivityAt = newestRecordAt
        }
        if let latestAgentText, let excerpt = AgentSessionPromptSummary.agentExcerpt(latestAgentText) {
            session.lastAgentMessage = excerpt
        } else if let raw = session.lastAgentMessage {
            // Codex `agent_message` records land here raw too.
            session.lastAgentMessage = AgentSessionPromptSummary.agentExcerpt(raw)
        }
        if candidate.provider == .claude, let entrypoint {
            session.host = AgentSessionJump.claudeHost(entrypoint: entrypoint, sessionID: session.id)
        }

        // The transcript's branch is preferred; this fills the gap when it says
        // "HEAD" or nothing at all but the project is a real checkout.
        if session.gitBranch == nil {
            session.gitBranch = gitBranch(at: session.workingDirectory)
        }

        if session.contextWindow == nil {
            session.contextWindow = AgentSession.inferredContextWindow(for: session.model)
        }
        // The agent's own wording about the work, for sessions that never got
        // an `ai-title` — already written as a short label, and about the task
        // rather than about the file.
        session.offer(agentPhrase(session), from: .agentPhrase)
        // Last, so a name a person typed outranks everything read above.
        known.apply(to: &session)
        if candidate.provider == .cursor, session.model == nil {
            session.model = CursorConversationModels.model(for: session.id)
        }
        if session.contextWindow == nil {
            session.contextWindow = AgentSession.inferredContextWindow(for: session.model)
        }

        // Only the leaders are kept: the store needs enough to tell whether the
        // file it is already showing still leads, not the whole histogram.
        session.focusScores = Dictionary(
            uniqueKeysWithValues: focus
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { ($0.key, $0.value) }
        )
        session.recentActivity = Array(collapseRepeats(activity).suffix(activityTail))
        guard !AgentSpawnedSessions.shared.hides(
            sessionID: session.id,
            workingDirectory: session.workingDirectory,
            isHeadless: entrypoint?.hasPrefix("sdk") == true
                || ["codex_exec", "codex_sdk_ts"].contains(codexOriginator ?? "")
        ) else { return nil }
        return session
    }

    private static func isSubagentTranscript(_ candidate: Candidate, opening: String) -> Bool {
        if candidate.url.pathComponents.contains(where: {
            $0.caseInsensitiveCompare("subagents") == .orderedSame
        }) {
            return true
        }

        guard candidate.provider == .codex else { return false }
        for line in opening.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = json(from: line),
                  (object["type"] as? String) == "session_meta"
            else { continue }
            let payload = (object["payload"] as? [String: Any]) ?? object
            if let source = payload["source"] as? [String: Any],
               source["subagent"] != nil {
                return true
            }
            if payload["subagent"] != nil { return true }
            return false
        }
        return false
    }

    /// Codex rollout filenames include a timestamp before the UUID. The
    /// canonical ID is in the opening `session_meta` record and is also the key
    /// used by hooks and the Codex app's thread-name index.
    private static func codexSessionID(from opening: String) -> String? {
        for line in opening.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = json(from: line),
                  (object["type"] as? String) == "session_meta"
            else { continue }
            let payload = object["payload"] as? [String: Any]
            if let id = payload?["id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Enough to hold the whole metadata record on one line. Codex writes
    /// 19-29KB there (it embeds the session instructions), so a smaller window
    /// truncates mid-JSON and the project path is silently lost.
    private static func head(of url: URL, limit: Int = 64_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Reads at most `tailBytes` from the end. Whole-file reads are what froze
    /// the app when a single transcript reached hundreds of megabytes.
    /// Fixed window, widened only on demand by the caller.
    private static func tail(of url: URL, size: Int64, bytes: Int64) -> String? {
        tailData(of: url, size: size, bytes: bytes).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func tailData(of url: URL, size: Int64, bytes: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let offset = max(size - bytes, 0)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return try? handle.readToEnd()
    }

    /// The retry window, used only when the narrow one produced no activity.
    private static let wideTailBytes: Int64 = 8_000_000

    fileprivate static func claudeRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []

        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            for part in configured.split(separator: ",") {
                let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let url = URL(fileURLWithPath: trimmed, isDirectory: true)
                roots.append(url.lastPathComponent == "projects"
                    ? url : url.appendingPathComponent("projects", isDirectory: true))
            }
        } else {
            roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
            roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
        }

        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Folds runs of the same call into one row with a count.
    ///
    /// A build loop produces the identical `codesign` line three times in a row.
    /// Shown separately they are three rows of noise; folded, the repetition
    /// itself becomes the information.
    private static func collapseRepeats(_ entries: [AgentActivityEntry]) -> [AgentActivityEntry] {
        var result: [AgentActivityEntry] = []

        for entry in entries {
            if let last = result.last,
               last.kind == entry.kind,
               last.detail == entry.detail,
               last.target == entry.target {
                result[result.count - 1] = AgentActivityEntry(
                    kind: last.kind,
                    detail: last.detail,
                    target: last.target,
                    at: entry.at,
                    repeatCount: last.repeatCount + 1
                )
                continue
            }
            result.append(entry)
        }
        return result
    }

    private static func activityEntries(from content: Any?, at: Date) -> [AgentActivityEntry] {
        guard let blocks = content as? [[String: Any]] else { return [] }

        return blocks.compactMap { block in
            guard (block["type"] as? String) == "tool_use",
                  let name = block["name"] as? String
            else { return nil }

            // Shared with the hook path, so a call looks the same whichever
            // source observed it.
            let described = AgentToolLabel.describe(
                tool: name,
                input: block["input"] as? [String: Any] ?? [:]
            )
            return AgentActivityEntry(
                kind: described.kind,
                detail: described.detail,
                target: described.target,
                at: at
            )
        }
    }

    /// Codex rollouts wrap messages and tools in event envelopes rather than
    /// Claude's content blocks. Normalize those envelopes before the shared
    /// aggregation below sees them.
    private static func applyCodexRecord(
        _ object: [String: Any],
        at: Date,
        recency: Double,
        session: inout AgentSession,
        activity: inout [AgentActivityEntry],
        focus: inout [String: Double],
        turns: inout [AgentConversationTurn]
    ) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        let outerType = object["type"] as? String
        let type = payload["type"] as? String

        if outerType == "event_msg", type == "user_message",
           let prompt = payload["message"] as? String,
           !prompt.isEmpty, !isSynthetic(prompt) {
            session.lastUserPrompt = firstLine(prompt)
            AgentConversationTurn.note(prompt: prompt, in: &turns)
        }
        if outerType == "event_msg", type == "agent_message",
           let message = payload["message"] as? String, !message.isEmpty {
            // Excerpted once by the caller after the loop.
            session.lastAgentMessage = message
            AgentConversationTurn.note(reply: message, in: &turns)
        }
        if outerType == "event_msg", type == "task_started",
           let window = payload["model_context_window"] as? Int {
            session.contextWindow = window
        }

        guard outerType == "response_item",
              type == "custom_tool_call" || type == "function_call"
        else { return }

        let name = payload["name"] as? String ?? "Tool"
        let input = codexToolInput(payload)
        // Code mode: `exec` carries a JavaScript program that calls the real
        // tools (`tools.exec_command({cmd:"…"})`). Showing the program put raw
        // `text(await tools.exec_command(…` on the island; show the calls.
        if name == "exec", let source = input["command"] as? String, source.contains("tools.") {
            for call in codexCodeModeCalls(source) {
                let described = AgentToolLabel.describe(tool: call.tool, input: call.input)
                activity.append(AgentActivityEntry(
                    kind: described.kind, detail: described.detail, target: described.target, at: at
                ))
                AgentConversationTurn.note(tool: described.kind, in: &turns)
                session.currentActivity = described.detail
                if let path = call.input["file_path"] as? String {
                    let file = URL(fileURLWithPath: path).lastPathComponent
                    focus[file, default: 0] += (described.kind == .edit ? 4 : 1) * recency
                }
            }
            return
        }
        // `js` drives an app and names each step itself.
        if name == "js", let title = input["title"] as? String, !title.isEmpty {
            activity.append(AgentActivityEntry(kind: .command, detail: title, target: nil, at: at))
            AgentConversationTurn.note(tool: .command, in: &turns)
            session.currentActivity = title
            return
        }
        if name == "sleep" { return }
        let described = AgentToolLabel.describe(tool: name, input: input)
        activity.append(AgentActivityEntry(
            kind: described.kind,
            detail: described.detail,
            target: described.target,
            at: at
        ))
        AgentConversationTurn.note(tool: described.kind, in: &turns)
        session.currentActivity = described.detail

        if let path = (input["file_path"] as? String) ?? (input["filePath"] as? String) {
            let file = URL(fileURLWithPath: path).lastPathComponent
            let weight: Double = described.kind == .edit ? 4 : 1
            focus[file, default: 0] += weight * recency
        }

        if name == "update_plan", let items = input["plan"] as? [[String: Any]] {
            session.todos = items.compactMap { item in
                guard let step = item["step"] as? String else { return nil }
                return (step, (item["status"] as? String) == "completed")
            }
        }
        if name == "spawn_agent", let task = input["message"] as? String {
            session.subagents.append(AgentSubagent(
                type: (input["task_name"] as? String) ?? "agent",
                task: firstLine(task)
            ))
        }
    }

    /// Tool calls inside a Codex code-mode program, in order. The arguments are
    /// JavaScript object literals, not JSON, so only the fields the labels use
    /// are lifted out: `cmd` for commands, the patched file for `apply_patch`.
    static func codexCodeModeCalls(_ source: String) -> [(tool: String, input: [String: Any])] {
        guard let regex = try? NSRegularExpression(pattern: #"tools\.([A-Za-z_]+)\("#) else { return [] }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return matches.enumerated().compactMap { index, match in
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let start = Range(match.range, in: source)?.upperBound
            else { return nil }
            let end = index + 1 < matches.count
                ? (Range(matches[index + 1].range, in: source)?.lowerBound ?? source.endIndex)
                : source.endIndex
            let segment = String(source[start..<end])
            let tool = String(source[nameRange])
            var input: [String: Any] = [:]
            if let command = firstCapture(#"cmd"?\s*:\s*("(?:\\.|[^"\\])*")"#, in: segment),
               let data = command.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                input["cmd"] = value
            }
            if let range = segment.range(of: #"\*\*\* (Update|Add|Delete) File: [^\\"\n]+"#, options: .regularExpression) {
                input["file_path"] = segment[range].components(separatedBy: "File: ").last?
                    .trimmingCharacters(in: .whitespaces)
            }
            return (tool, input)
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func codexToolInput(_ payload: [String: Any]) -> [String: Any] {
        if let input = payload["input"] as? [String: Any] { return input }
        if let arguments = payload["arguments"] as? [String: Any] { return arguments }
        let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return raw.isEmpty ? [:] : ["command": raw]
    }

    /// The agent's own short phrasing for what it is doing, if it left one.
    ///
    /// A plan's first line is its heading, a todo list opens on the task it was
    /// written for, and a subagent brief is three to five words by convention.
    /// All three are worth more than anything that could be extracted from the
    /// user's prompt, which is prose and often dictated.
    private static func agentPhrase(_ session: AgentSession) -> String? {
        if let heading = session.plan?
            .split(separator: "\n", omittingEmptySubsequences: true).first {
            let text = heading
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*- ").union(.whitespaces))
            if !text.isEmpty { return truncated(text, 44) }
        }
        if let todo = session.todos.first?.title { return truncated(todo, 44) }
        if let subagent = session.subagents.first {
            return truncated(subagent.displayName, 44)
        }
        return nil
    }

    /// Files a session reads to find out where it is, in any project.
    private static let orientationDocs: Set<String> = [
        "HANDOFF.md", "README.md", "CLAUDE.md", "AGENTS.md", "MEMORY.md",
        "CONTRIBUTING.md", "package.json",
    ]

    /// What a tool call says about where a session lives.
    ///
    /// Edits count for far more than reads: agents read all over a repository
    /// and edit where the work actually is. Weighing reads at all is what keeps
    /// a session that has only been investigating from having no label.
    private static func focusWeights(from content: Any?) -> [(String, Double)] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        var weights: [(String, Double)] = []

        for block in blocks {
            guard (block["type"] as? String) == "tool_use",
                  let name = block["name"] as? String,
                  let input = block["input"] as? [String: Any],
                  let path = input["file_path"] as? String
            else { continue }

            var weight: Double
            let isEdit: Bool
            switch name {
            case "Edit", "MultiEdit", "Write", "NotebookEdit": weight = 4; isEdit = true
            case "Read", "NotebookRead": weight = 1; isEdit = false
            default: continue
            }

            // Build output, dependencies and dotfiles are traffic, not subject
            // matter — naming a session after `project.pbxproj` would say
            // nothing about it.
            let file = URL(fileURLWithPath: path).lastPathComponent
            guard !file.hasPrefix("."),
                  !path.contains("/DerivedData/"),
                  !path.contains("/node_modules/"),
                  !path.contains("/.git/"),
                  !path.contains("/build/")
            else { continue }

            // Reading the orientation docs is how a session starts and writing
            // them is how it signs off; neither is what the session is about.
            // Left at full weight they name every session in a project the
            // same thing, which is the failure this label exists to fix. Kept
            // above zero so a session that touched nothing else still lands
            // somewhere true.
            if orientationDocs.contains(file) { weight = isEdit ? 0.5 : 0.2 }
            weights.append((file, weight))
        }
        return weights
    }

    /// Plan markdown from `ExitPlanMode`, the only place an agent states one.
    private static func planText(from content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            guard (block["type"] as? String) == "tool_use",
                  (block["name"] as? String) == "ExitPlanMode",
                  let input = block["input"] as? [String: Any],
                  let plan = input["plan"] as? String,
                  !plan.isEmpty
            else { continue }
            return plan
        }
        return nil
    }

    /// The subagent tool is `Agent` in this harness and `Task` in others; both
    /// carry the same `subagent_type` and `description`.
    private static func subagents(from content: Any?, at: Date) -> [AgentSubagent] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard (block["type"] as? String) == "tool_use",
                  let name = block["name"] as? String,
                  name == "Agent" || name == "Task",
                  let input = block["input"] as? [String: Any]
            else { return nil }
            return AgentSubagent(
                type: (input["subagent_type"] as? String) ?? "agent",
                task: (input["description"] as? String) ?? "Delegated work",
                toolUseID: block["id"] as? String,
                startedAt: at,
                isBackground: (input["run_in_background"] as? Bool) == true
            )
        }
    }

    /// Line deltas from the edit payloads themselves. A replaced line counts on
    /// both sides, matching diff convention.
    private static func fileChanges(from content: Any?) -> [AgentFileChange] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        var changes: [AgentFileChange] = []

        for block in blocks {
            guard (block["type"] as? String) == "tool_use",
                  let name = block["name"] as? String,
                  ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name),
                  let input = block["input"] as? [String: Any]
            else { continue }

            let old = (input["old_string"] as? String) ?? ""
            let new = (input["new_string"] as? String)
                ?? (input["content"] as? String)
                ?? ""
            var change = AgentFileChange(
                path: (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            )
            if !old.isEmpty { change.removed = old.count(where: { $0 == "\n" }) + 1 }
            if !new.isEmpty { change.added = new.count(where: { $0 == "\n" }) + 1 }
            AgentFileChange.merging([change], into: &changes)
        }
        return changes
    }

    private static func todoList(from content: Any?) -> [(title: String, done: Bool)]? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            guard (block["type"] as? String) == "tool_use",
                  (block["name"] as? String) == "TodoWrite",
                  let input = block["input"] as? [String: Any],
                  let todos = input["todos"] as? [[String: Any]]
            else { continue }

            return todos.compactMap { todo in
                guard let title = todo["content"] as? String else { return nil }
                return (title, (todo["status"] as? String) == "completed")
            }
        }
        return nil
    }

    /// Reads the branch from the repository itself.
    ///
    /// The transcript only reports a branch some of the time, and writes "HEAD"
    /// when there is none. If the session's directory is a real checkout, the
    /// branch is right there in `.git/HEAD`, so read it rather than showing
    /// nothing for a project that genuinely has one.
    private static func gitBranch(at directory: String?) -> String? {
        guard let directory else { return nil }

        var url = URL(fileURLWithPath: directory, isDirectory: true)
        // Walk up: agents often run from a subdirectory of the checkout.
        for _ in 0..<4 {
            let head = url.appendingPathComponent(".git/HEAD")
            if let text = try? String(contentsOf: head, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = trimmed.range(of: "refs/heads/") {
                    return String(trimmed[range.upperBound...])
                }
                // Detached: a bare commit hash is not a branch name.
                return nil
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return nil
    }

    /// Harness-injected messages arrive with `role: "user"` but are not things
    /// the user typed. Taking the last user message verbatim meant a background
    /// build notification outranked the actual question on screen.
    /// Claude Code's note on a screenshot it scaled down, sent as its own text
    /// block ahead of what the user typed.
    private static func isImageNote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[Image: original ") && trimmed.hasSuffix("]") && !trimmed.contains("\n")
    }

    private static func isSynthetic(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") , trimmed.contains(">") { return true }
        if trimmed.compare("[Image]", options: .caseInsensitive) == .orderedSame {
            return true
        }
        // Claude Code's reply when a deferred tool's schema is loaded. It is
        // the harness talking, not the user.
        if trimmed == "Tool loaded." { return true }
        if isImageNote(trimmed) { return true }
        for marker in [
            "[SYSTEM NOTIFICATION", "Caveat:", "<system-reminder>",
            "<task-notification>", "<command-name>", "<local-command",
            "This is how Claude Code surfaces", "tool_use_error",
        ] where trimmed.contains(marker) {
            return true
        }
        return false
    }

    private static func plainText(from content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            let type = block["type"] as? String
            guard type == "text" || type == "input_text" || type == "output_text" else {
                continue
            }
            if let text = block["text"] as? String, !isImageNote(text) { return text }
        }
        return nil
    }

    private static func readableProjectName(_ mangled: String) -> String {
        if let recovered = recoverMangledPath(mangled) {
            return URL(fileURLWithPath: recovered).lastPathComponent
        }
        return URL(fileURLWithPath: unmangle(mangled)).lastPathComponent
    }

    /// Cursor encodes the absolute path with `/` (and spaces) as `-`. Blindly
    /// turning every dash into a slash names `acme-core-platform` as
    /// `foundation`. Walk the real filesystem, longest match first.
    static func recoverMangledPath(_ mangled: String) -> String? {
        let parts = mangled
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .split(separator: "-")
            .map(String.init)
        guard !parts.isEmpty else { return nil }

        var path = "/"
        var consumed = 0
        while consumed < parts.count {
            let remaining = Array(parts[consumed...])
            var matched: String?
            var taken = 0
            for count in stride(from: remaining.count, through: 1, by: -1) {
                let slice = remaining.prefix(count)
                for joiner in ["-", " "] {
                    let name = slice.joined(separator: joiner)
                    let candidate = path == "/" ? "/" + name : path + "/" + name
                    if FileManager.default.fileExists(atPath: candidate) {
                        matched = candidate
                        taken = count
                        break
                    }
                }
                if matched != nil { break }
            }
            guard let matched, taken > 0 else { return nil }
            path = matched
            consumed += taken
        }
        return path
    }

    /// Claude Code names project folders after the path with separators
    /// replaced by dashes, which is lossy — dashes inside a real directory name
    /// are indistinguishable from separators.
    private static func unmangle(_ mangled: String) -> String {
        "/" + mangled.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .replacingOccurrences(of: "-", with: "/")
    }

    private static func firstLine(_ text: String) -> String {
        return truncated(AgentSessionPromptSummary.line(text), 120)
    }

    private static func truncated(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "\u{2026}"
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func json(from line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func json(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func nested(_ object: [String: Any], _ key: String) -> [String: Any]? {
        if let direct = object[key] as? [String: Any] { return direct }
        if let payload = object["payload"] as? [String: Any] {
            return payload[key] as? [String: Any]
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int {
        (value as? Int) ?? Int((value as? Double) ?? 0)
    }

    private static func date(fromISO text: String) -> Date? {
        NanoISO8601.date(text)
    }
}

/// Attachment envelopes are transport metadata, not a useful task summary.
enum AgentSessionPromptSummary {
    static func line(_ text: String) -> String {
        var content = decodingEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("# Files mentioned by the user:"),
           let request = content.range(of: "## My request:") {
            content = String(content[request.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content.split(separator: "\n").first.map(String.init) ?? content
    }

    /// The whole prompt on one line, for the conversation view.
    static func body(_ text: String, limit: Int = 400) -> String? {
        var content = decodingEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("# Files mentioned by the user:"),
           let request = content.range(of: "## My request:") {
            content = String(content[request.upperBound...])
        }
        let joined = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return joined.count <= limit ? joined : String(joined.prefix(limit - 1)) + "\u{2026}"
    }

    /// Some hosts store prompts HTML-escaped (`we're having.&#x20;`).
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in named where entity != "&amp;" {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        while let range = result.range(of: #"&#[xX]?[0-9A-Fa-f]{1,6};"#, options: .regularExpression) {
            let body = result[range].dropFirst(2).dropLast()
            let isHex = body.first == "x" || body.first == "X"
            let scalar = UInt32(isHex ? String(body.dropFirst()) : String(body), radix: isHex ? 16 : 10)
                .flatMap(Unicode.Scalar.init)
            result.replaceSubrange(range, with: scalar.map { String(Character($0)) } ?? "")
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The agent's reply as a short, readable excerpt: markdown chrome and code
    /// blocks dropped, whitespace collapsed.
    static func agentExcerpt(_ text: String, limit: Int = 280) -> String? {
        var lines: [String] = []
        var inFence = false
        for raw in decodingEntities(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty || line.hasPrefix("|") || line.hasPrefix("---") { continue }
            let stripped = line
                .replacingOccurrences(of: #"^(#+|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if !stripped.isEmpty { lines.append(stripped) }
        }
        let joined = lines.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return joined.count <= limit ? joined : String(joined.prefix(limit - 1)) + "\u{2026}"
    }
}
