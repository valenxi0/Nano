import Foundation
import SQLite3
import XCTest
@testable import Nano

final class TokenLedgerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-ledger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    // MARK: Claude

    private func claudeLine(id: String, input: Int, cacheRead: Int, output: Int) -> String {
        """
        {"timestamp":"2026-08-03T10:00:00.000Z","requestId":"req_\(id)",\
        "message":{"id":"\(id)","model":"claude-opus-5","usage":{"input_tokens":\(input),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    @discardableResult
    private func writeClaudeLog(_ lines: [String], append: Bool = false) -> URL {
        let url = temporaryRoot.appendingPathComponent("session.jsonl")
        let text = lines.joined(separator: "\n") + "\n"
        if append, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        return url
    }

    private func totals(_ output: ScanOutput) -> NanoTokenCounts {
        output.deltas.reduce(NanoTokenCounts()) { $0 + $1.counts }
    }

    func testCursorScanBanksAnthropicStyleUsageAsCursor() {
        writeClaudeLog([claudeLine(id: "msg_cursor", input: 8, cacheRead: 40, output: 3)])
        let output = TokenScanners.scanCursor(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(output.deltas.first?.provider, "cursor")
        XCTAssertEqual(totals(output).freshInput, 8)
        XCTAssertEqual(totals(output).cacheRead, 40)
        XCTAssertEqual(totals(output).output, 3)
    }

    func testClaudeScanBanksOnlyAppendedBytes() {
        writeClaudeLog([claudeLine(id: "msg_a", input: 10, cacheRead: 100, output: 20)])

        let first = TokenScanners.scanClaude(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(totals(first).freshInput, 10)
        XCTAssertEqual(totals(first).cacheRead, 100)
        XCTAssertEqual(totals(first).output, 20)

        // A restated copy of the first message (the straddle case) plus a new
        // one stated twice in the same chunk: only the new message may land,
        // and only once.
        writeClaudeLog([
            claudeLine(id: "msg_a", input: 10, cacheRead: 100, output: 20),
            claudeLine(id: "msg_b", input: 5, cacheRead: 50, output: 7),
            claudeLine(id: "msg_b", input: 5, cacheRead: 50, output: 7),
        ], append: true)

        let second = TokenScanners.scanClaude(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).freshInput, 5)
        XCTAssertEqual(totals(second).cacheRead, 50)
        XCTAssertEqual(totals(second).output, 7)
    }

    func testClaudeScanReReadsRotatedFileFromScratch() {
        writeClaudeLog([claudeLine(id: "msg_a", input: 10, cacheRead: 0, output: 20)])
        let first = TokenScanners.scanClaude(watermarks: [:], roots: [temporaryRoot])

        // Rotation replaces the file with a shorter one holding new messages.
        writeClaudeLog([claudeLine(id: "msg_c", input: 3, cacheRead: 0, output: 4)])
        let second = TokenScanners.scanClaude(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).freshInput, 3)
        XCTAssertEqual(totals(second).output, 4)
    }

    func testClaudeScanReadsForwardAcrossLimitNotTheTail() {
        let lines = (1...8).map { claudeLine(id: "msg_\($0)", input: $0, cacheRead: 0, output: 1) }
        writeClaudeLog(lines)
        let oneLine = Int64(claudeLine(id: "msg_1", input: 1, cacheRead: 0, output: 1).utf8.count + 1)

        let first = TokenScanners.scanClaude(
            watermarks: [:], roots: [temporaryRoot], readLimit: oneLine * 3
        )
        // Old tail-jump would have banked msg_6…8. Lifetime has to start at msg_1.
        XCTAssertEqual(totals(first).freshInput, 1 + 2 + 3)
        XCTAssertLessThan(
            first.watermarks.values.first?.offset ?? 0,
            (try? FileManager.default.attributesOfItem(atPath: temporaryRoot.appendingPathComponent("session.jsonl").path)[.size] as? Int64) ?? 0
        )

        let second = TokenScanners.scanClaude(
            watermarks: first.watermarks, roots: [temporaryRoot], readLimit: oneLine * 3
        )
        XCTAssertEqual(totals(second).freshInput, 4 + 5 + 6)

        let third = TokenScanners.scanClaude(
            watermarks: second.watermarks, roots: [temporaryRoot], readLimit: oneLine * 3
        )
        XCTAssertEqual(totals(third).freshInput, 7 + 8)
    }

    func testClaudeScanRetriesPartialTrailingLine() throws {
        let url = writeClaudeLog([claudeLine(id: "msg_a", input: 10, cacheRead: 0, output: 20)])
        let partial = "{\"timestamp\":\"2026-08-03T10:01:00.000Z\",\"message\":{\"id\":\"msg_b\",\""
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(partial.utf8))
            try? handle.close()
        }

        let first = TokenScanners.scanClaude(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(totals(first).freshInput, 10)
        let size = try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        let watermark = try XCTUnwrap(first.watermarks.values.first)
        XCTAssertLessThan(watermark.offset, size)

        // The writer finishes the line; the next scan must pick it up.
        let rest = "model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7}}}\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(rest.utf8))
            try? handle.close()
        }
        let second = TokenScanners.scanClaude(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).freshInput, 5)
        XCTAssertEqual(totals(second).output, 7)
    }

    /// The read limit is a byte count, so it can land inside a multi-byte
    /// character. That used to fail the decode and skip the file every scan.
    func testClaudeScanSurvivesLimitInsideMultiByteCharacter() throws {
        let first = claudeLine(id: "msg_a", input: 10, cacheRead: 0, output: 20)
        let prefix = "{\"pad\":\""
        let second = prefix + "\u{20AC}\",\"timestamp\":\"2026-08-03T10:01:00.000Z\","
            + "\"message\":{\"id\":\"msg_b\",\"model\":\"claude-opus-5\","
            + "\"usage\":{\"input_tokens\":5,\"output_tokens\":7}}}"
        writeClaudeLog([first, second])

        // One byte into the three-byte euro sign.
        let firstLineBytes = Int64(first.utf8.count + 1)
        let limit = firstLineBytes + Int64(prefix.utf8.count) + 1
        let cut = TokenScanners.scanClaude(watermarks: [:], roots: [temporaryRoot], readLimit: limit)
        XCTAssertEqual(totals(cut).freshInput, 10)
        XCTAssertEqual(try XCTUnwrap(cut.watermarks.values.first).offset, firstLineBytes)

        let rest = TokenScanners.scanClaude(watermarks: cut.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(rest).freshInput, 5)
        XCTAssertEqual(totals(rest).output, 7)
    }

    /// Some lines state only the flat cache-write total, with no per-TTL
    /// `cache_creation` object. Those tokens still have to be banked.
    func testClaudeScanBanksFlatCacheCreationWithoutBreakdown() {
        let flat = "{\"timestamp\":\"2026-08-03T10:00:00.000Z\",\"message\":{\"id\":\"msg_flat\","
            + "\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1,"
            + "\"cache_creation_input_tokens\":300,\"output_tokens\":2}}}"
        let detailed = "{\"timestamp\":\"2026-08-03T10:00:01.000Z\",\"message\":{\"id\":\"msg_detail\","
            + "\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1,"
            + "\"cache_creation_input_tokens\":50,\"cache_creation\":{"
            + "\"ephemeral_5m_input_tokens\":20,\"ephemeral_1h_input_tokens\":30},"
            + "\"output_tokens\":2}}}"
        writeClaudeLog([flat, detailed])

        let counts = totals(TokenScanners.scanClaude(watermarks: [:], roots: [temporaryRoot]))
        // 300 flat, plus the breakdown's 20 without its flat 50 on top.
        XCTAssertEqual(counts.cacheWrite5m, 320)
        XCTAssertEqual(counts.cacheWrite1h, 30)
    }

    // MARK: Codex

    /// One `token_count` event. `total` is what Codex would report as the
    /// running total at that point, which only the reconciliation test reads.
    private func codexUsageLine(
        at timestamp: String,
        input: Int,
        cached: Int,
        output: Int,
        total: (input: Int, cached: Int, output: Int)? = nil
    ) -> String {
        let running = total ?? (input, cached, output)
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":\(running.input),\
        "cached_input_tokens":\(running.cached),"cache_write_input_tokens":0,\
        "output_tokens":\(running.output),"reasoning_output_tokens":0},\
        "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0}}}}
        """
    }

    private func codexMeta(at timestamp: String, forkedFrom: String? = nil) -> String {
        let fork = forkedFrom.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"ses_codex"\(fork)}}
        """
    }

    private func codexTurnContext(at timestamp: String, model: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)"}}
        """
    }

    @discardableResult
    private func writeCodexLog(_ lines: [String], name: String = "rollout.jsonl") -> URL {
        let url = temporaryRoot.appendingPathComponent(name)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// The invariant the scanner rests on: on a session that is not a fork,
    /// per-turn deltas add up to the running total Codex reports.
    func testCodexPerTurnDeltasReconcile() {
        writeCodexLog([
            codexMeta(at: "2026-08-03T10:00:00.000Z"),
            codexTurnContext(at: "2026-08-03T10:00:01.000Z", model: "gpt-5.6-sol"),
            codexUsageLine(
                at: "2026-08-03T10:00:10.000Z",
                input: 1000, cached: 200, output: 50,
                total: (1000, 200, 50)
            ),
            codexUsageLine(
                at: "2026-08-03T10:00:30.000Z",
                input: 1200, cached: 900, output: 70,
                total: (2200, 1100, 120)
            ),
        ])

        let scan = TokenScanners.scanCodex(watermarks: [:], roots: [temporaryRoot])
        let counts = totals(scan)
        // Running total: 2200 input of which 1100 cached, 120 output.
        XCTAssertEqual(counts.freshInput, 1100)
        XCTAssertEqual(counts.cacheRead, 1100)
        XCTAssertEqual(counts.output, 120)
        XCTAssertEqual(scan.deltas.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(scan.deltas.first?.day, "2026-08-03")
    }

    /// A fork opens with its parent's history re-stamped to the fork instant.
    /// Only the turn after the burst is this session's own work.
    func testCodexForkSkipsReplayedParentHistory() {
        writeCodexLog([
            codexMeta(at: "2026-08-03T10:00:00.000Z", forkedFrom: "ses_parent"),
            codexTurnContext(at: "2026-08-03T10:00:00.001Z", model: "gpt-5.6-sol"),
            codexUsageLine(at: "2026-08-03T10:00:00.010Z", input: 5000, cached: 4000, output: 300),
            codexUsageLine(at: "2026-08-03T10:00:00.030Z", input: 6000, cached: 5000, output: 400),
            // 8 seconds later: the child's own first turn.
            codexUsageLine(at: "2026-08-03T10:00:08.000Z", input: 700, cached: 100, output: 20),
        ])

        let counts = totals(
            TokenScanners.scanCodex(watermarks: [:], roots: [temporaryRoot])
        )
        XCTAssertEqual(counts.freshInput, 600)
        XCTAssertEqual(counts.cacheRead, 100)
        XCTAssertEqual(counts.output, 20)
    }

    /// Codex restates the last usage event verbatim when a turn moved nothing.
    func testCodexIgnoresRestatedUsageEvent() {
        writeCodexLog([
            codexMeta(at: "2026-08-03T10:00:00.000Z"),
            codexTurnContext(at: "2026-08-03T10:00:01.000Z", model: "gpt-5.6-sol"),
            codexUsageLine(at: "2026-08-03T10:00:10.000Z", input: 900, cached: 100, output: 30),
            codexUsageLine(at: "2026-08-03T10:00:20.000Z", input: 900, cached: 100, output: 30),
        ])

        let counts = totals(
            TokenScanners.scanCodex(watermarks: [:], roots: [temporaryRoot])
        )
        XCTAssertEqual(counts.freshInput, 800)
        XCTAssertEqual(counts.output, 30)
    }

    /// A rollout too big to read in one pass, so the budget actually bites.
    ///
    /// Lines are read in 4MB blocks, so anything smaller than a block finishes
    /// in a single pass whatever the budget says — a small fixture would test
    /// nothing here.
    private static let bulkTurns = 28_000

    private func writeBulkCodexLog() -> Int {
        var lines = [
            codexMeta(at: "2026-08-03T10:00:00.000Z"),
            codexTurnContext(at: "2026-08-03T10:00:01.000Z", model: "gpt-5.6-sol"),
        ]
        // Values that never repeat back to back, so none is dropped as a
        // restatement of the one before it.
        var expectedInput = 0
        for index in 0..<Self.bulkTurns {
            let input = 100 + index % 997
            expectedInput += input
            lines.append(codexUsageLine(
                at: "2026-08-03T10:00:10.000Z", input: input, cached: 0, output: 10
            ))
        }
        writeCodexLog(lines)
        return expectedInput
    }

    /// A rollout bigger than one scan's budget is read forward across scans.
    /// Jumping to the tail instead, as the Claude reader does, would drop every
    /// turn before the jump — and 83 rollouts on this machine are over 64MB.
    func testCodexLargeFileIsConsumedAcrossScansWithoutSkipping() {
        let expectedInput = writeBulkCodexLog()

        var watermarks: [String: NanoScanWatermark] = [:]
        var seen = NanoTokenCounts()
        var passes = 0
        for _ in 0..<20 {
            let scan = TokenScanners.scanCodex(
                watermarks: watermarks, roots: [temporaryRoot], budget: 4_000_000
            )
            passes += 1
            seen += totals(scan)
            watermarks = scan.watermarks
            if scan.backlogBytes == 0 { break }
        }

        XCTAssertGreaterThan(passes, 1, "the budget has to split this file across passes")
        XCTAssertEqual(seen.freshInput, expectedInput)
        XCTAssertEqual(seen.output, Self.bulkTurns * 10)
    }

    /// The catch-up figure exists so a long first scan does not look hung, so
    /// it has to fall as passes land and reach nothing when the file is read.
    func testCodexReportsShrinkingBacklogUntilCaughtUp() {
        _ = writeBulkCodexLog()

        var watermarks: [String: NanoScanWatermark] = [:]
        var backlog: [Int64] = []
        for _ in 0..<20 {
            let scan = TokenScanners.scanCodex(
                watermarks: watermarks, roots: [temporaryRoot], budget: 4_000_000
            )
            XCTAssertTrue(scan.reportsBacklog)
            backlog.append(scan.backlogBytes)
            watermarks = scan.watermarks
            if scan.backlogBytes == 0 { break }
        }

        XCTAssertGreaterThan(backlog.first ?? 0, 0, "a part-read file is still outstanding")
        XCTAssertEqual(backlog.last, 0, "the backlog has to reach zero")
        XCTAssertEqual(backlog, backlog.sorted(by: >), "it must never grow")
    }

    /// A live rollout ends in a half-written line. It cannot be consumed yet,
    /// so reporting it as backlog kept the catch-up loop scanning forever.
    func testCodexUnterminatedTailIsNotBacklog() {
        let url = writeCodexLog([
            codexMeta(at: "2026-08-03T10:00:00.000Z"),
            codexTurnContext(at: "2026-08-03T10:00:01.000Z", model: "gpt-5.6-sol"),
            codexUsageLine(at: "2026-08-03T10:00:10.000Z", input: 900, cached: 100, output: 30),
        ])
        let pending = codexUsageLine(at: "2026-08-03T10:00:20.000Z", input: 700, cached: 100, output: 20)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(pending.prefix(60).utf8))
            try? handle.close()
        }

        let first = TokenScanners.scanCodex(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(totals(first).output, 30)
        XCTAssertEqual(first.backlogBytes, 0, "a half-written last line is not outstanding history")

        let second = TokenScanners.scanCodex(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).total, 0)
        XCTAssertEqual(second.backlogBytes, 0)

        // The writer finishes the line; it is counted then, and only once.
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((String(pending.dropFirst(60)) + "\n").utf8))
            try? handle.close()
        }
        let third = TokenScanners.scanCodex(watermarks: second.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(third).freshInput, 600)
        XCTAssertEqual(totals(third).output, 20)
        XCTAssertEqual(third.backlogBytes, 0)
    }

    /// The fork flag and the running model live at the top of the file, which an
    /// incremental scan never re-reads — they have to survive on the watermark.
    func testCodexResumeKeepsModelAndForkStateAcrossScans() {
        let url = writeCodexLog([
            codexMeta(at: "2026-08-03T10:00:00.000Z", forkedFrom: "ses_parent"),
            codexTurnContext(at: "2026-08-03T10:00:00.001Z", model: "gpt-5.6-sol"),
            codexUsageLine(at: "2026-08-03T10:00:00.010Z", input: 5000, cached: 4000, output: 300),
        ])
        let first = TokenScanners.scanCodex(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(totals(first).total, 0, "the replayed burst is not this session's usage")

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            // Still inside the burst, then the child's own turn after a pause.
            handle.write(Data((
                codexUsageLine(at: "2026-08-03T10:00:00.040Z", input: 6000, cached: 5000, output: 400)
                    + "\n"
                    + codexUsageLine(at: "2026-08-03T10:00:09.000Z", input: 700, cached: 100, output: 20)
                    + "\n"
            ).utf8))
            try? handle.close()
        }

        let second = TokenScanners.scanCodex(
            watermarks: first.watermarks, roots: [temporaryRoot]
        )
        let counts = totals(second)
        XCTAssertEqual(counts.freshInput, 600)
        XCTAssertEqual(counts.output, 20)
        XCTAssertEqual(second.deltas.first?.model, "gpt-5.6-sol", "model came from the file head")
    }

    func testCodexArchivedRolloutIsNotCountedAgain() throws {
        let name = "rollout-2026-08-03T10-00-00-019e0000-0000-7000-8000-000000000000.jsonl"
        let url = writeCodexLog([
            codexMeta(at: "2026-08-03T10:00:00.000Z"),
            codexUsageLine(at: "2026-08-03T10:00:10.000Z", input: 1000, cached: 200, output: 50),
        ], name: name)
        let first = TokenScanners.scanCodex(watermarks: [:], roots: [temporaryRoot])
        XCTAssertGreaterThan(totals(first).total, 0)

        let archive = temporaryRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: archive.appendingPathComponent(name))

        let second = TokenScanners.scanCodex(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).total, 0)
    }

    // MARK: OpenCode

    private func makeOpenCodeDB() throws -> URL {
        let url = temporaryRoot.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE message (
          id text PRIMARY KEY,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return url
    }

    private func upsertMessage(
        _ db: URL, id: String, created: Int64, updated: Int64,
        role: String = "assistant", provider: String = "kimi-for-coding",
        model: String = "k3", input: Int, cacheRead: Int, cacheWrite: Int, output: Int
    ) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let data = """
        {"role":"\(role)","modelID":"\(model)","providerID":"\(provider)","cost":0,\
        "tokens":{"input":\(input),"output":\(output),"reasoning":0,\
        "cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}
        """
        let sql = """
        INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('\(id)', 'ses_1', \(created), \(updated), '\(data)');
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func testOpenCodeScanBanksRowGrowthAndAttributesProvider() throws {
        let db = try makeOpenCodeDB()
        let dayStart = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        // A step mid-stream: partial tokens, and a user row that must be ignored.
        upsertMessage(db, id: "msg_1", created: dayStart, updated: dayStart + 1_000,
                      input: 100, cacheRead: 1000, cacheWrite: 10, output: 5)
        upsertMessage(db, id: "msg_2", created: dayStart, updated: dayStart + 2_000,
                      role: "user", input: 0, cacheRead: 0, cacheWrite: 0, output: 0)

        let first = TokenScanners.scanOpenCode(watermarks: [:], banked: [:], databaseURL: db)
        XCTAssertEqual(first.deltas.count, 1)
        // Harness vendor strings normalize onto the provider Nano knows.
        XCTAssertEqual(first.deltas.first?.provider, "kimi")
        XCTAssertEqual(first.deltas.first?.model, "k3")
        XCTAssertEqual(totals(first).cacheRead, 1000)

        // The stream completes: tokens grow in place, only the growth counts.
        upsertMessage(db, id: "msg_1", created: dayStart, updated: dayStart + 5_000,
                      input: 100, cacheRead: 1000, cacheWrite: 10, output: 42)
        let second = TokenScanners.scanOpenCode(
            watermarks: first.watermarks, banked: first.banked, databaseURL: db
        )
        XCTAssertEqual(second.deltas.count, 1)
        XCTAssertEqual(totals(second).output, 37)
        XCTAssertEqual(totals(second).cacheRead, 0)

        // Nothing new: no deltas, no double counting.
        let third = TokenScanners.scanOpenCode(
            watermarks: second.watermarks, banked: second.banked, databaseURL: db
        )
        XCTAssertTrue(third.deltas.isEmpty)
    }

    // MARK: Pi

    private func piLine(model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int) -> String {
        """
        {"type":"message","timestamp":"2026-08-03T10:00:00.000Z",\
        "message":{"role":"assistant","model":"\(model)",\
        "usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),"totalTokens":0}}}
        """
    }

    func testPiScanCountsAssistantUsageIncrementally() {
        let url = temporaryRoot.appendingPathComponent("session.jsonl")
        try? Data((piLine(model: "gpt-5", input: 100, cacheRead: 10, cacheWrite: 20, output: 50) + "\n").utf8)
            .write(to: url)

        let first = TokenScanners.scanPi(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(first.deltas.first?.provider, "pi")
        XCTAssertEqual(first.deltas.first?.model, "gpt-5")
        XCTAssertEqual(totals(first).freshInput, 100)
        XCTAssertEqual(totals(first).cacheWrite5m, 20)
        XCTAssertEqual(totals(first).output, 50)

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((piLine(model: "gpt-5", input: 7, cacheRead: 0, cacheWrite: 0, output: 3) + "\n").utf8))
            try? handle.close()
        }
        let second = TokenScanners.scanPi(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).freshInput, 7)
        XCTAssertEqual(totals(second).output, 3)
    }

    // MARK: Kimi CLI

    func testKimiCLIScanReadsOldWireFormatWithConfigModel() {
        try? Data(#"{"model":"kimi-k2"}"#.utf8)
            .write(to: temporaryRoot.appendingPathComponent("config.json"))
        let sessionDir = temporaryRoot.appendingPathComponent("sessions/group/session-a", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let wire = """
        {"type":"metadata","protocol_version":"1.3"}
        {"timestamp":1770983426.420942,"message":{"type":"TurnBegin","payload":{"user_input":"hello"}}}
        {"timestamp":1770983427.123,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":50,"input_cache_read":10,"input_cache_creation":20},"message_id":"msg-1"}}}
        """
        try? Data((wire + "\n").utf8).write(to: sessionDir.appendingPathComponent("wire.jsonl"))

        let first = TokenScanners.scanKimiCLI(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(first.deltas.count, 1)
        XCTAssertEqual(first.deltas.first?.provider, "kimi")
        XCTAssertEqual(first.deltas.first?.model, "kimi-k2")
        XCTAssertEqual(first.deltas.first?.day, "2026-02-13")
        XCTAssertEqual(totals(first).freshInput, 100)
        XCTAssertEqual(totals(first).cacheRead, 10)
        XCTAssertEqual(totals(first).cacheWrite5m, 20)
        XCTAssertEqual(totals(first).output, 50)

        // A restated message id must not count twice.
        let restated = """
        {"timestamp":1770983428.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":50,"input_cache_read":10,"input_cache_creation":20},"message_id":"msg-1"}}}
        {"timestamp":1770983429.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":5,"output":2,"input_cache_read":0,"input_cache_creation":0},"message_id":"msg-2"}}}
        """
        if let handle = try? FileHandle(forWritingTo: sessionDir.appendingPathComponent("wire.jsonl")) {
            handle.seekToEndOfFile()
            handle.write(Data((restated + "\n").utf8))
            try? handle.close()
        }
        let second = TokenScanners.scanKimiCLI(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertEqual(totals(second).freshInput, 5)
        XCTAssertEqual(totals(second).output, 2)
    }

    func testKimiCLIScanCountsOnlyTurnScopeRecords() {
        let sessionDir = temporaryRoot.appendingPathComponent("sessions/ws/session-b/agents/agent-1", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let wire = """
        {"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":3064,"output":76,"inputCacheRead":14848,"inputCacheCreation":0},"usageScope":"turn","time":1782113184943}
        {"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":5000,"output":200,"inputCacheRead":20000,"inputCacheCreation":100},"usageScope":"session","time":1782113185000}
        """
        try? Data((wire + "\n").utf8).write(to: sessionDir.appendingPathComponent("wire.jsonl"))

        let output = TokenScanners.scanKimiCLI(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(output.deltas.count, 1)
        XCTAssertEqual(output.deltas.first?.model, "kimi-for-coding")
        XCTAssertEqual(totals(output).freshInput, 3064)
        XCTAssertEqual(totals(output).cacheRead, 14848)
        XCTAssertEqual(totals(output).output, 76)
    }

    // MARK: Gemini CLI

    private func writeGeminiChat(_ messages: [String]) -> URL {
        let chats = temporaryRoot.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let doc = """
        {"sessionId":"abc","startTime":"2026-08-03T09:00:00.000Z","messages":[\(messages.joined(separator: ","))]}
        """
        let url = chats.appendingPathComponent("session-1.json")
        try? Data(doc.utf8).write(to: url)
        return url
    }

    func testGeminiScanBanksDocumentGrowthAndNormalizesCachedInput() {
        // Restated id m1: last write wins. total == input+output means the
        // input figure still holds the cached share (400 comes out).
        writeGeminiChat([
            #"{"type":"user","id":"u1"}"#,
            #"{"type":"gemini","id":"m1","model":"gemini-3.5-flash","timestamp":"2026-08-03T10:00:00.000Z","tokens":{"input":1000,"output":100,"cached":400,"total":1100}}"#,
            #"{"type":"gemini","id":"m1","model":"gemini-3.5-flash","timestamp":"2026-08-03T10:00:01.000Z","tokens":{"input":1200,"output":150,"cached":400,"total":1350}}"#,
        ])

        let first = TokenScanners.scanGemini(watermarks: [:], banked: [:], roots: [temporaryRoot])
        XCTAssertEqual(first.deltas.first?.provider, "gemini")
        XCTAssertEqual(totals(first).freshInput, 800)
        XCTAssertEqual(totals(first).cacheRead, 400)
        XCTAssertEqual(totals(first).output, 150)

        // The document grows by one message; only the growth lands.
        writeGeminiChat([
            #"{"type":"gemini","id":"m1","model":"gemini-3.5-flash","timestamp":"2026-08-03T10:00:01.000Z","tokens":{"input":1200,"output":150,"cached":400,"total":1350}}"#,
            #"{"type":"gemini","id":"m2","model":"gemini-3.5-flash","timestamp":"2026-08-03T10:05:00.000Z","tokens":{"input":500,"output":50,"cached":0,"total":550}}"#,
        ])
        let second = TokenScanners.scanGemini(
            watermarks: first.watermarks, banked: first.banked, roots: [temporaryRoot]
        )
        XCTAssertEqual(totals(second).freshInput, 500)
        XCTAssertEqual(totals(second).output, 50)
        XCTAssertEqual(totals(second).cacheRead, 0)
    }

    func testGeminiScanRecountsReplacedDocument() {
        writeGeminiChat([
            #"{"type":"gemini","id":"m1","model":"gemini-3.5-flash","timestamp":"2026-08-03T10:00:00.000Z","tokens":{"input":1000,"output":100,"cached":0,"total":1100}}"#,
        ])
        let first = TokenScanners.scanGemini(watermarks: [:], banked: [:], roots: [temporaryRoot])

        writeGeminiChat([
            #"{"type":"gemini","id":"m9","model":"gemini-3.5-flash","timestamp":"2026-08-03T11:00:00.000Z","tokens":{"input":10,"output":5,"cached":0,"total":15}}"#,
        ])
        let second = TokenScanners.scanGemini(
            watermarks: first.watermarks, banked: first.banked, roots: [temporaryRoot]
        )
        XCTAssertEqual(totals(second).freshInput, 10)
        XCTAssertEqual(totals(second).output, 5)
    }

    // MARK: Pricing

    func testKimiForCodingPricesAtMoonshotListRates() {
        let pricing = NanoModelPricing()
        let counts = NanoTokenCounts(freshInput: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let nanos = pricing.costNanos(
            provider: "kimi-for-coding", model: "k3", day: "2026-08-03", counts: counts
        )
        // kimi-k3 list rates: $3 input, $15 output per 1M, cache read at 0.1x input.
        XCTAssertEqual(nanos, Int((3.0 + 0.3 + 15.0) * 1_000_000_000))
    }

    func testDevinRowsPriceFromDevinRateCard() {
        let card = """
        {"families":[
          {"variants":[{"model_uid":"swe-2-high","cost_tier":"Free"}]},
          {"variants":[{"model_uid":"kimi-k2-7","cost_tier":"Low cost",
            "cost_summary":"$0.95 / 1M Input · $0.19 / 1M Cached input · $4 / 1M Output"}]},
          {"variants":[{"model_uid":"gpt-6-luna-medium","cost_tier":"Low cost",
            "cost_summary":"$0.1 / 1M Input · $0.01 / 1M Cached input · $0.5 / 1M Output"}]},
          {"variants":[{"model_uid":"fusion-opus","cost_tier":"High cost",
            "cost_summary":"$10 / 1M Input · $0.25 / 1M Cached input · $50 / 1M Output · $1 / 1M Sidekick input · $0.1 / 1M Sidekick cached input · $5 / 1M Sidekick output"}]}
        ]}
        """
        let pricing = NanoModelPricing(devinCardData: Data(card.utf8), loadCache: false)
        let million = NanoTokenCounts(freshInput: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        func cost(_ model: String) -> Int? {
            pricing.costNanos(provider: "devin", model: model, day: "2026-09-23", counts: million)
        }

        // Free is a real $0, not unpriced.
        XCTAssertEqual(cost("swe-2-high"), 0)
        XCTAssertEqual(cost("kimi-k2-7"), Int((0.95 + 0.19 + 4.0) * 1_000_000_000))
        // Devin labels its compactor "Compactor (Luna)".
        XCTAssertEqual(cost("compactor"), Int((0.1 + 0.01 + 0.5) * 1_000_000_000))
        // Sidekick rates bill a separately logged helper, not this row.
        XCTAssertEqual(cost("fusion-opus"), Int((10.0 + 0.25 + 50.0) * 1_000_000_000))
        XCTAssertNil(cost("summarizer"))
    }

    /// xAI publishes no cache-write price because written tokens bill as
    /// input. Cursor Grok rows with a cache write used to go unpriced.
    func testCacheWritesWithoutPublishedPriceBillAsInput() {
        let pricing = NanoModelPricing(loadCache: false)
        let counts = NanoTokenCounts(freshInput: 1_000_000, cacheWrite5m: 1_000_000)
        XCTAssertEqual(
            pricing.costNanos(provider: "cursor", model: "grok-bot-default", day: "2026-09-23", counts: counts),
            Int(4.0 * 1_000_000_000)
        )
    }

    func testCursorOwnModelsAndPreviewNamesArePriced() {
        let pricing = NanoModelPricing(loadCache: false)
        let million = NanoTokenCounts(freshInput: 1_000_000, output: 1_000_000)
        XCTAssertEqual(
            pricing.costNanos(provider: "cursor", model: "composer-2.5-fast", day: "2026-09-17", counts: million),
            Int(18.0 * 1_000_000_000)
        )
        XCTAssertEqual(
            pricing.costNanos(provider: "cursor", model: "composer-2.5", day: "2026-09-17", counts: million),
            Int(3.0 * 1_000_000_000)
        )
        let catalog = #"{"google":{"models":{"gemini-3.1-pro-preview":{"cost":{"input":2,"output":12}}}}}"#
        let withCatalog = NanoModelPricing(catalogData: Data(catalog.utf8), loadCache: false)
        XCTAssertEqual(
            withCatalog.costNanos(provider: "cursor", model: "gemini-3.1-pro", day: "2026-09-15", counts: million),
            Int(14.0 * 1_000_000_000)
        )
    }

    func testPiUsagePricesByModelIdWithoutVendor() {
        let pricing = NanoModelPricing()
        let counts = NanoTokenCounts(freshInput: 1_000_000, output: 1_000_000)
        // "pi" is a harness, not a vendor: resolution falls back to matching
        // the model id across providers (claude-opus-5 at $5/$25).
        let nanos = pricing.costNanos(
            provider: "pi", model: "claude-opus-5", day: "2026-08-03", counts: counts
        )
        XCTAssertEqual(nanos, Int(30.0 * 1_000_000_000))
    }

    /// Cursor logs vendor models with a `cursor-` prefix and effort tags the
    /// catalog never lists. Those have to peel down to the list-price id.
    func testCursorHarnessNamesPriceAtVendorListRates() {
        let pricing = NanoModelPricing()
        let million = NanoTokenCounts(freshInput: 1_000_000, output: 1_000_000)

        // Grok 4.6 list: $2 input / $6 output. Effort and the cursor- prefix
        // must not leave the row unpriced.
        XCTAssertEqual(
            pricing.costNanos(
                provider: "cursor",
                model: "cursor-grok-4.6-high-fast",
                day: "2026-08-17",
                counts: million
            ),
            Int(8.0 * 1_000_000_000)
        )
        // Cursor's Grok routing lane is Grok 4.6, even without a conversation
        // model to rewrite the stored name.
        for lane in ["grok-bot", "grok-bot-default", "grok-bot-cua"] {
            XCTAssertEqual(
                pricing.costNanos(
                    provider: "cursor",
                    model: lane,
                    day: "2026-09-16",
                    counts: million
                ),
                Int(8.0 * 1_000_000_000),
                lane
            )
        }
        XCTAssertEqual(
            pricing.costNanos(
                provider: "cursor",
                model: "cursor-grok-4.6-high",
                day: "2026-08-17",
                counts: million
            ),
            Int(8.0 * 1_000_000_000)
        )

        // Opus 4.8 list: $5 / $25. Cursor appends `-thinking-high`.
        XCTAssertEqual(
            pricing.costNanos(
                provider: "cursor",
                model: "claude-opus-4-8-thinking-high",
                day: "2026-08-17",
                counts: million
            ),
            Int(30.0 * 1_000_000_000)
        )

        // `gpt-5.6-sol-medium` is the catalog id plus effort. Price it the
        // same as bare `gpt-5.6-sol` whenever the catalog has that row.
        if pricing.rate(provider: "openai", model: "gpt-5.6-sol") != nil {
            XCTAssertEqual(
                pricing.costNanos(
                    provider: "cursor",
                    model: "gpt-5.6-sol-medium",
                    day: "2026-08-17",
                    counts: million
                ),
                pricing.costNanos(
                    provider: "openai",
                    model: "gpt-5.6-sol",
                    day: "2026-08-17",
                    counts: million
                )
            )
        }
    }

    func testAstraOfflineRatesAndLongContextLane() {
        let pricing = NanoModelPricing(loadCache: false)
        let counts = NanoTokenCounts(freshInput: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 1_000_000, output: 1_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "codex", model: "gpt-6-astra", day: "2026-09-04", counts: counts), 73_500_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "codex", model: "gpt-6-astra", day: "2026-09-04", counts: counts, longContext: true), 122_000_000_000)
        XCTAssertNotNil(pricing.rate(provider: "cursor", model: "openai/gpt-6-astra-2026-09-01-ultra"))
    }

    func testProviderSpecificCachePricesAndSonnetCorrection() throws {
        let data = Data(#"{"openai":{"models":{"gpt-4o":{"cost":{"input":2.5,"output":10,"cache_read":1.25}}}}}"#.utf8)
        let pricing = NanoModelPricing(catalogData: data, loadCache: false)
        let million = NanoTokenCounts(cacheRead: 1_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "codex", model: "gpt-4o", day: "", counts: million), 1_250_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "claude", model: "claude-fable-5-1", day: "", counts: million), 250_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "grok", model: "grok-4.6", day: "", counts: million), 500_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "kimi", model: "kimi-k2.6", day: "", counts: million), 160_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "claude", model: "claude-sonnet-5", day: "", counts: NanoTokenCounts(freshInput: 1_000_000, output: 1_000_000)), 12_000_000_000)
        XCTAssertEqual(pricing.costNanos(provider: "claude", model: "claude-sonnet-5", day: "", counts: NanoTokenCounts(cacheWrite1h: 1_000_000)), 4_000_000_000)
    }

    func testMissingCacheRateIsNotFreeAndVendorCannotBorrowRouterRate() throws {
        let data = Data(#"{"openai":{"models":{"gpt-test":{"cost":{"input":1,"output":2}},"gpt-free":{"cost":{"input":0,"output":0,"cache_read":0}}}},"router":{"models":{"gpt-unknown":{"cost":{"input":0,"output":0}}}}}"#.utf8)
        let pricing = NanoModelPricing(catalogData: data, loadCache: false)
        XCTAssertNil(pricing.costNanos(provider: "codex", model: "gpt-test", day: "", counts: NanoTokenCounts(cacheRead: 1)))
        XCTAssertEqual(pricing.costNanos(provider: "codex", model: "gpt-free", day: "", counts: NanoTokenCounts(cacheRead: 1)), 0)
        XCTAssertNil(pricing.rate(provider: "codex", model: "gpt-unknown"))
        XCTAssertNil(pricing.rate(provider: "pi", model: "mystery-model"))
    }

    func testCacheOnlyRateChangeInvalidatesPricingFingerprint() {
        let a = Data(#"{"google":{"models":{"gemini-test":{"cost":{"input":1,"output":2,"cache_read":0.1}}}}}"#.utf8)
        let b = Data(#"{"google":{"models":{"gemini-test":{"cost":{"input":1,"output":2,"cache_read":0.2}}}}}"#.utf8)
        XCTAssertNotEqual(NanoModelPricing(catalogData: a, loadCache: false).pricingFingerprint, NanoModelPricing(catalogData: b, loadCache: false).pricingFingerprint)
    }

    // MARK: Display contracts

    func testLifetimeDayParsesAsCalendarStartNotInstallDate() throws {
        let parsed = try XCTUnwrap(TokenLedger.date(fromDay: "2026-04-26"))
        XCTAssertEqual(TokenLedger.dayString(parsed), "2026-04-26")
        XCTAssertNil(TokenLedger.date(fromDay: "April 26"))
    }

    func testProcessedTotalIncludesCacheReadsAndNewTokensExcludeThem() {
        let counts = NanoTokenCounts(
            freshInput: 666_000_000,
            cacheRead: 11_640_000_000,
            cacheWrite5m: 20_000_000,
            cacheWrite1h: 13_000_000,
            output: 29_000_000,
            reasoning: 7_000_000
        )
        XCTAssertEqual(counts.total, 12_368_000_000)
        XCTAssertEqual(AgentModuleView.compact(13_600_000_000), "13.6B")
        XCTAssertEqual(AgentModuleView.compact(734_000_000), "734M")
    }

    // MARK: Grok CLI

    func testGrokCLIScanCountsTurnUsageAndStripsBuildSuffix() {
        let sessionDir = temporaryRoot.appendingPathComponent(
            "sessions/%2Ftmp%2FNano/01a0-session", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line = """
        {"timestamp":1770983427,"method":"_x.ai/session/update","params":{"sessionId":"01a0-session","update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":1000,"outputTokens":80,"cachedReadTokens":400,"cacheCreationTokens":20,"reasoningTokens":30,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":80,"cachedReadTokens":400,"cacheCreationTokens":20,"reasoningTokens":30}}}},"_meta":{"eventId":"evt-1"}}}
        """
        try? Data((line + "\n").utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let first = TokenScanners.scanGrokCLI(watermarks: [:], roots: [temporaryRoot])
        XCTAssertEqual(first.deltas.first?.provider, "grok")
        XCTAssertEqual(first.deltas.first?.model, "grok-4.6")
        XCTAssertEqual(totals(first).freshInput, 600)
        XCTAssertEqual(totals(first).cacheRead, 400)
        XCTAssertEqual(totals(first).cacheWrite5m, 20)
        XCTAssertEqual(totals(first).output, 80)
        XCTAssertEqual(totals(first).reasoning, 30)

        if let handle = try? FileHandle(forWritingTo: sessionDir.appendingPathComponent("updates.jsonl")) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
        let second = TokenScanners.scanGrokCLI(watermarks: first.watermarks, roots: [temporaryRoot])
        XCTAssertTrue(second.deltas.isEmpty)
    }

    func testEverySupportedProviderHasATokenSource() {
        for provider in AgentProviderID.supported {
            XCTAssertFalse(
                TokenScanners.sources(for: [provider]).isEmpty,
                "\(provider.rawValue) is in Settings but has no scanner"
            )
        }
        XCTAssertEqual(
            TokenScanners.sources(for: [.cursor]),
            Set(["cursor", "cursor-events", "cursor-history"])
        )
    }

    func testCursorEventsDedupAndSkipPassthroughCLI() {
        let composer = CursorUsageAdapter.event(from: [
            "timestamp": "1786942800000",
            "model": "composer-2.5",
            "requestId": "req-1",
            "conversationId": "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
            "tokenUsage": [
                "inputTokens": 100,
                "outputTokens": 20,
                "cacheReadTokens": 400,
                "cacheWriteTokens": 50,
            ],
        ])
        XCTAssertEqual(composer?.model, "composer-2.5")
        XCTAssertEqual(composer?.conversationID, "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad")
        XCTAssertEqual(composer?.counts.freshInput, 100)
        XCTAssertEqual(composer?.counts.cacheRead, 400)
        XCTAssertEqual(composer?.counts.cacheWrite5m, 50)
        XCTAssertEqual(composer?.counts.output, 20)

        XCTAssertNil(CursorUsageAdapter.event(from: [
            "timestamp": "1786942800000",
            "model": "codex-cli",
            "tokenUsage": ["inputTokens": 10, "outputTokens": 2],
        ]))
        XCTAssertNil(CursorUsageAdapter.event(from: [
            "timestamp": "1786942800000",
            "model": "claude-code",
            "tokenUsage": ["inputTokens": 10, "outputTokens": 2],
        ]))
        XCTAssertTrue(CursorUsageAdapter.isPassthroughCLI("codex-cli"))
        XCTAssertFalse(CursorUsageAdapter.isPassthroughCLI("composer-2.5"))

        let payload = """
        {"usageEventsDisplay":[
          {"timestamp":"1786942800000","model":"composer-2.5","requestId":"req-1",
           "tokenUsage":{"inputTokens":100,"outputTokens":20}},
          {"timestamp":"1786942801000","model":"grok-4.6","requestId":"req-2",
           "tokenUsage":{"inputTokens":8,"outputTokens":3}}
        ]}
        """.data(using: .utf8)!
        let events = CursorUsageAdapter.parseTokenEvents(payload)
        XCTAssertEqual(events.map(\.id), ["req-1", "req-2"])

        let first = TokenScanners.output(fromCursorEvents: events, banked: [:])
        XCTAssertEqual(first.deltas.count, 2)
        XCTAssertEqual(first.deltas.map(\.provider), ["cursor", "cursor"])
        XCTAssertEqual(Set(first.banked.keys), ["cursor://event/req-1", "cursor://event/req-2"])

        let second = TokenScanners.output(fromCursorEvents: events, banked: first.banked)
        XCTAssertTrue(second.deltas.isEmpty)
    }

    func testCursorRoutingLabelUsesAuthoritativeConversationModel() {
        let event = CursorUsageAdapter.TokenEvent(
            id: "req-routed",
            timestampMs: 1_786_942_800_000,
            model: "grok-bot-default",
            counts: NanoTokenCounts(freshInput: 100, output: 20),
            conversationID: "conversation-routed"
        )

        let output = TokenScanners.output(
            fromCursorEvents: [event],
            banked: [:],
            authoritativeModels: ["conversation-routed": "grok-4.6"]
        )

        XCTAssertEqual(output.deltas.first?.model, "grok-4.6")
    }

    func testCursorRoutingLabelPricesAsGrok46WithoutAuthoritativeModel() {
        let event = CursorUsageAdapter.TokenEvent(
            id: "req-unknown-route",
            timestampMs: 1_786_942_800_000,
            model: "grok-bot-default",
            counts: NanoTokenCounts(freshInput: 100, output: 20),
            conversationID: "conversation-without-runtime"
        )

        let output = TokenScanners.output(
            fromCursorEvents: [event],
            banked: [:],
            authoritativeModels: [:]
        )

        XCTAssertEqual(output.deltas.first?.model, "grok-bot-default")
        XCTAssertEqual(
            NanoModelPricing(loadCache: false).costNanos(
                provider: "cursor",
                model: output.deltas[0].model,
                day: output.deltas[0].day,
                counts: output.deltas[0].counts
            ),
            NanoModelPricing(loadCache: false).costNanos(
                provider: "cursor",
                model: "grok-4.6",
                day: output.deltas[0].day,
                counts: output.deltas[0].counts
            )
        )
    }

    func testPreviouslyBankedCursorRoutingLabelEmitsModelCorrection() throws {
        let event = CursorUsageAdapter.TokenEvent(
            id: "req-previously-banked",
            timestampMs: 1_786_942_800_000,
            model: "grok-bot-default",
            counts: NanoTokenCounts(freshInput: 100, output: 20),
            conversationID: "conversation-now-resolved"
        )
        let banked = ["cursor://event/req-previously-banked": event.counts]

        let output = TokenScanners.output(
            fromCursorEvents: [event],
            banked: banked,
            authoritativeModels: ["conversation-now-resolved": "grok-4.6"]
        )

        XCTAssertTrue(output.deltas.isEmpty)
        let correction = try XCTUnwrap(output.modelCorrections.first)
        XCTAssertEqual(correction.oldModel, "grok-bot-default")
        XCTAssertEqual(correction.newModel, "grok-4.6")
        XCTAssertEqual(correction.counts, event.counts)

        let updatedBanked = banked.merging(output.banked) { _, new in new }
        let repeated = TokenScanners.output(
            fromCursorEvents: [event],
            banked: updatedBanked,
            authoritativeModels: ["conversation-now-resolved": "grok-4.6"]
        )
        XCTAssertTrue(repeated.modelCorrections.isEmpty)
    }

    func testHiddenCodexModelWithoutPublishedPriceStaysUnpriced() {
        XCTAssertNil(
            NanoModelPricing(loadCache: false).costNanos(
                provider: "codex",
                model: "gpt-reserve",
                day: "2026-09-11",
                counts: NanoTokenCounts(freshInput: 100, output: 20)
            )
        )
    }

    func testOnlyRoutingLabelConversationsRequestHistoricalRepair() {
        XCTAssertEqual(
            CursorConversationModels.routingConversationIDs(in: [
                "needs-repair": "grok-bot-default",
                "needs-repair-cua": "grok-bot-cua",
                "already-canonical": "grok-4.6",
                "other-provider-model": "claude-fable-5-1",
            ]),
            ["needs-repair", "needs-repair-cua"]
        )
    }

    func testCursorConversationModelsFillAgentWindowSessions() {
        let older = CursorUsageAdapter.event(from: [
            "timestamp": "1786942800000",
            "model": "composer-2.5",
            "requestId": "req-old",
            "conversationId": "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
            "tokenUsage": ["inputTokens": 10, "outputTokens": 2],
        ])
        let newer = CursorUsageAdapter.event(from: [
            "timestamp": "1786942900000",
            "model": "grok-4.6",
            "requestId": "req-new",
            "conversation_id": "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
            "tokenUsage": ["inputTokens": 64_000, "outputTokens": 0],
        ])
        let mapped = CursorConversationModels.latestModels(
            from: [newer, older].compactMap { $0 }
        )
        XCTAssertEqual(mapped["232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad"], "grok-4.6")
        let contexts = CursorConversationModels.latestContextUsed(
            from: [newer, older].compactMap { $0 }
        )
        XCTAssertEqual(contexts["232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad"], 64_000)

        let routed = CursorUsageAdapter.TokenEvent(
            id: "req-routed-model-cache",
            timestampMs: 1_786_943_000_000,
            model: "grok-bot-default",
            counts: NanoTokenCounts(freshInput: 10),
            conversationID: "routed-conversation"
        )
        XCTAssertEqual(
            CursorConversationModels.latestModels(
                from: [routed],
                authoritativeModels: ["routed-conversation": "grok-4.6"]
            )["routed-conversation"],
            "grok-4.6"
        )

        var sessions = [
            AgentSession(
                id: "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
                provider: .cursor,
                projectName: "acme-core-platform",
                lastActivityAt: Date()
            ),
            AgentSession(
                id: "already-named",
                provider: .cursor,
                projectName: "other",
                lastActivityAt: Date()
            ),
            AgentSession(
                id: "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
                provider: .codex,
                projectName: "not-cursor",
                lastActivityAt: Date()
            ),
        ]
        sessions[1].model = "composer-2.5"
        CursorConversationModels.apply(
            ["232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad": "grok-4.6", "already-named": "ignored"],
            contextUsed: contexts,
            to: &sessions
        )
        XCTAssertEqual(sessions[0].model, "grok-4.6")
        XCTAssertEqual(sessions[0].contextUsed, 64_000)
        XCTAssertEqual(sessions[0].contextWindow, 500_000)
        XCTAssertEqual(sessions[0].contextFraction, 0.128)
        XCTAssertEqual(sessions[1].model, "composer-2.5")
        XCTAssertNil(sessions[2].model)
    }

    func testTokenSummaryBreakdownListsProviders() {
        let text = AgentTokenSummary.breakdown(
            counts: NanoTokenCounts(freshInput: 10, cacheRead: 90, output: 8),
            costNanos: 5_000_000_000,
            providers: [
                (
                    provider: "codex",
                    counts: NanoTokenCounts(freshInput: 8, cacheRead: 80, output: 6),
                    costNanos: 4_000_000_000
                ),
                (
                    provider: "cursor",
                    counts: NanoTokenCounts(freshInput: 2, cacheRead: 10, output: 2),
                    costNanos: 1_000_000_000
                ),
            ]
        )
        XCTAssertTrue(text.contains("Codex"))
        XCTAssertTrue(text.contains("Cursor"))
        XCTAssertTrue(text.contains("All"))
        XCTAssertTrue(text.contains("Priced at list API rates"))
        XCTAssertFalse(text.contains("Uncached"))
    }

    /// `codex-auto-review` names a role, not a model, so it prices at whatever
    /// Codex shipped as current on the row's day — and at nothing without one.
    func testCodexAutoReviewPricesByTheDayItRan() {
        let data = Data(#"{"openai":{"models":{"gpt-5.5":{"cost":{"input":5,"output":30,"cache_read":0.5}}}}}"#.utf8)
        let pricing = NanoModelPricing(catalogData: data, loadCache: false)
        let counts = NanoTokenCounts(freshInput: 1_000_000, output: 1_000_000)

        XCTAssertNotNil(
            pricing.costNanos(
                provider: "codex", model: "codex-auto-review", day: "2026-08-03", counts: counts
            )
        )
        XCTAssertNil(
            pricing.costNanos(
                provider: "codex", model: "codex-auto-review", day: "", counts: counts
            )
        )
    }

    // MARK: Provider grouping

    private func modelTotal(
        _ provider: String,
        _ model: String,
        total: Int,
        costNanos: Int,
        priced: Bool = true
    ) -> NanoTokenModelTotal {
        NanoTokenModelTotal(
            provider: provider,
            model: model,
            counts: NanoTokenCounts(freshInput: total),
            costNanos: costNanos,
            priced: priced
        )
    }

    func testProviderGroupingSumsTokensAndPricedCost() {
        let groups = NanoTokenProviderGroup.grouping([
            modelTotal("cursor", "gpt-5.5", total: 100, costNanos: 10),
            modelTotal("cursor", "claude-opus-5", total: 50, costNanos: 20),
            modelTotal("claude", "claude-opus-5", total: 30, costNanos: 5),
        ])

        XCTAssertEqual(groups.map(\.provider), ["cursor", "claude"])
        let cursor = groups[0]
        XCTAssertEqual(cursor.counts.total, 150)
        XCTAssertEqual(cursor.costNanos, 30)
        XCTAssertFalse(cursor.hasUnpriced)
        XCTAssertFalse(cursor.allUnpriced)
    }

    func testProviderGroupingOrdersGroupsByCostThenTokensThenName() {
        let groups = NanoTokenProviderGroup.grouping([
            modelTotal("claude", "m", total: 10, costNanos: 5),
            modelTotal("codex", "m", total: 20, costNanos: 5),
            modelTotal("amp", "m", total: 1, costNanos: 50),
        ])

        XCTAssertEqual(groups.map(\.provider), ["amp", "codex", "claude"])
    }

    func testProviderGroupingOrdersModelsByCostWithinAGroup() {
        let groups = NanoTokenProviderGroup.grouping([
            modelTotal("codex", "cheap", total: 999, costNanos: 1),
            modelTotal("codex", "dear", total: 5, costNanos: 100),
        ])

        XCTAssertEqual(groups[0].models.map(\.model), ["dear", "cheap"])
    }

    func testProviderGroupingTracksUnpricedFlags() {
        let mixed = NanoTokenProviderGroup.grouping([
            modelTotal("cursor", "priced", total: 10, costNanos: 10),
            modelTotal("cursor", "free", total: 10, costNanos: 0, priced: false),
        ])
        XCTAssertTrue(mixed[0].hasUnpriced)
        XCTAssertFalse(mixed[0].allUnpriced)
        XCTAssertEqual(mixed[0].costNanos, 10)

        let allFree = NanoTokenProviderGroup.grouping([
            modelTotal("pi", "free-a", total: 5, costNanos: 0, priced: false),
            modelTotal("pi", "free-b", total: 5, costNanos: 0, priced: false),
        ])
        XCTAssertTrue(allFree[0].hasUnpriced)
        XCTAssertTrue(allFree[0].allUnpriced)
        XCTAssertEqual(allFree[0].costNanos, 0)
    }

    func testProviderGroupingKeepsUnknownProviderStrings() {
        let groups = NanoTokenProviderGroup.grouping([
            modelTotal("some-future-cli", "m", total: 7, costNanos: 3),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].provider, "some-future-cli")
        XCTAssertEqual(groups[0].id, "some-future-cli")
    }

    // MARK: Devin CLI

    private func makeDevinDB() throws -> URL {
        let url = temporaryRoot.appendingPathComponent("devin-sessions.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE sessions (id TEXT PRIMARY KEY);
        CREATE TABLE message_nodes (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          node_id INTEGER NOT NULL,
          parent_node_id INTEGER,
          chat_message TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          metadata TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return url
    }

    private func insertDevinNode(
        _ db: URL, node: Int, requestID: String,
        model: String = "claude-fable-5-1-medium",
        createdISO: String = "2026-09-22T04:51:29.669122Z",
        input: Int, cacheRead: Int, cacheWrite: Int, output: Int
    ) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let message = """
        {"role":"assistant","metadata":{"request_id":"\(requestID)",\
        "generation_model":"\(model)","created_at":"\(createdISO)",\
        "metrics":{"input_tokens":\(input),"cache_read_tokens":\(cacheRead),\
        "cache_creation_tokens":\(cacheWrite),"output_tokens":\(output)}}}
        """
        let sql = """
        INSERT INTO message_nodes (session_id, node_id, chat_message, created_at)
        VALUES ('ses_1', \(node), '\(message)', 1774900000);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private func mergeBanked(
        _ base: [String: NanoTokenCounts], _ extra: [String: NanoTokenCounts]
    ) -> [String: NanoTokenCounts] {
        base.merging(extra) { _, new in new }
    }

    func testDevinScanCountsSiblingRequestIDsOnceAndResumes() throws {
        let db = try makeDevinDB()
        // Conversation-tree siblings repeat one request_id with identical counts.
        insertDevinNode(db, node: 1, requestID: "req-a",
                        input: 4, cacheRead: 12_584, cacheWrite: 22_244, output: 316)
        insertDevinNode(db, node: 2, requestID: "req-a",
                        input: 4, cacheRead: 12_584, cacheWrite: 22_244, output: 316)

        let first = TokenScanners.scanDevin(watermarks: [:], banked: [:], databaseURL: db)
        XCTAssertEqual(first.deltas.count, 1)
        XCTAssertEqual(first.deltas.first?.provider, "devin")
        XCTAssertEqual(first.deltas.first?.model, "claude-fable-5-1-medium")
        XCTAssertEqual(totals(first).freshInput, 4)
        XCTAssertEqual(totals(first).cacheRead, 12_584)
        XCTAssertEqual(totals(first).cacheWrite5m, 22_244)
        XCTAssertEqual(totals(first).output, 316)

        let second = TokenScanners.scanDevin(
            watermarks: first.watermarks, banked: first.banked, databaseURL: db
        )
        XCTAssertTrue(second.deltas.isEmpty)

        // A new row past the watermark resumes cleanly.
        insertDevinNode(db, node: 3, requestID: "req-b",
                        input: 10, cacheRead: 0, cacheWrite: 0, output: 7)
        let third = TokenScanners.scanDevin(
            watermarks: second.watermarks,
            banked: mergeBanked(first.banked, second.banked),
            databaseURL: db
        )
        XCTAssertEqual(totals(third).freshInput, 10)
        XCTAssertEqual(totals(third).output, 7)
    }

    // MARK: Kilo Code

    func testKiloScanOverridesProviderWhileOpenCodeKeepsVendor() throws {
        let db = try makeOpenCodeDB()
        let dayStart = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        upsertMessage(db, id: "msg_1", created: dayStart, updated: dayStart + 1_000,
                      provider: "kimi-for-coding", model: "k3",
                      input: 100, cacheRead: 1000, cacheWrite: 10, output: 5)

        let kilo = TokenScanners.scanKilo(watermarks: [:], banked: [:], databaseURL: db)
        XCTAssertEqual(kilo.deltas.count, 1)
        XCTAssertEqual(kilo.deltas.first?.provider, "kilo")
        XCTAssertEqual(totals(kilo).freshInput, 100)

        // The same row read as OpenCode still attributes to the row's vendor.
        let openCode = TokenScanners.scanOpenCode(watermarks: [:], banked: [:], databaseURL: db)
        XCTAssertEqual(openCode.deltas.first?.provider, "kimi")
    }

    // MARK: Goose

    private func makeGooseDB(usageLedger: Bool) throws -> URL {
        let url = temporaryRoot.appendingPathComponent("goose-sessions.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema: String
        if usageLedger {
            schema = """
            CREATE TABLE usage_ledger (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT,
              created_timestamp INTEGER,
              model TEXT,
              input_tokens INTEGER,
              output_tokens INTEGER,
              total_tokens INTEGER,
              cache_read_tokens INTEGER,
              cache_write_tokens INTEGER,
              cost REAL,
              cost_source TEXT,
              is_compaction INTEGER
            );
            """
        } else {
            schema = """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              accumulated_input_tokens INTEGER,
              accumulated_output_tokens INTEGER,
              accumulated_cache_read_tokens INTEGER,
              accumulated_cache_write_tokens INTEGER,
              model_config_json TEXT,
              updated_at INTEGER
            );
            """
        }
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return url
    }

    private func insertGooseLedgerRow(
        _ db: URL, model: String?, input: Int, output: Int,
        cacheRead: Int, cacheWrite: Int, costSource: String = "api"
    ) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let modelSQL = model.map { "'\($0)'" } ?? "NULL"
        let sql = """
        INSERT INTO usage_ledger
          (session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES ('ses_1', 1774900000, \(modelSQL), \(input), \(output), 0,
                \(cacheRead), \(cacheWrite), 0, '\(costSource)', 0);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func testGooseUsageLedgerSubtractsCacheAndDefaultsCarriedForwardModel() throws {
        let db = try makeGooseDB(usageLedger: true)
        // Goose folds cache reads and writes into input_tokens.
        insertGooseLedgerRow(db, model: "claude-opus-5", input: 1000, output: 50,
                             cacheRead: 300, cacheWrite: 100)
        insertGooseLedgerRow(db, model: nil, input: 200, output: 10,
                             cacheRead: 0, cacheWrite: 0, costSource: "carried_forward")

        let first = TokenScanners.scanGoose(watermarks: [:], banked: [:], databaseURL: db)
        XCTAssertEqual(first.deltas.count, 2)
        XCTAssertEqual(first.deltas.first?.provider, "goose")
        XCTAssertEqual(first.deltas.first?.model, "claude-opus-5")
        XCTAssertEqual(first.deltas.last?.model, "unknown")
        XCTAssertEqual(totals(first).freshInput, 600 + 200)
        XCTAssertEqual(totals(first).cacheRead, 300)
        XCTAssertEqual(totals(first).cacheWrite5m, 100)
        XCTAssertEqual(totals(first).output, 60)

        let second = TokenScanners.scanGoose(
            watermarks: first.watermarks, banked: first.banked, databaseURL: db
        )
        XCTAssertTrue(second.deltas.isEmpty)
    }

    private func upsertGooseSession(
        _ db: URL, id: String, input: Int, output: Int,
        cacheRead: Int, cacheWrite: Int, model: String, updatedAt: Int64
    ) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
        INSERT OR REPLACE INTO sessions
          (id, accumulated_input_tokens, accumulated_output_tokens,
           accumulated_cache_read_tokens, accumulated_cache_write_tokens,
           model_config_json, updated_at)
        VALUES ('\(id)', \(input), \(output), \(cacheRead), \(cacheWrite),
                '{"model_name":"\(model)"}', \(updatedAt));
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func testGooseSessionsFallbackRestatesCumulativeTotals() throws {
        let db = try makeGooseDB(usageLedger: false)
        upsertGooseSession(db, id: "s1", input: 1000, output: 100,
                           cacheRead: 200, cacheWrite: 50,
                           model: "claude-sonnet-4", updatedAt: 1_774_900_000)

        let first = TokenScanners.scanGoose(watermarks: [:], banked: [:], databaseURL: db)
        XCTAssertEqual(first.deltas.count, 1)
        XCTAssertEqual(first.deltas.first?.model, "claude-sonnet-4")
        XCTAssertEqual(totals(first).freshInput, 750)
        XCTAssertEqual(totals(first).cacheRead, 200)
        XCTAssertEqual(totals(first).cacheWrite5m, 50)
        XCTAssertEqual(totals(first).output, 100)

        // The session restates bigger cumulative totals; only growth lands.
        upsertGooseSession(db, id: "s1", input: 1500, output: 160,
                           cacheRead: 300, cacheWrite: 80,
                           model: "claude-sonnet-4", updatedAt: 1_774_900_100)
        let second = TokenScanners.scanGoose(
            watermarks: first.watermarks, banked: first.banked, databaseURL: db
        )
        XCTAssertEqual(totals(second).freshInput, 370)
        XCTAssertEqual(totals(second).cacheRead, 100)
        XCTAssertEqual(totals(second).cacheWrite5m, 30)
        XCTAssertEqual(totals(second).output, 60)

        let third = TokenScanners.scanGoose(
            watermarks: second.watermarks,
            banked: mergeBanked(first.banked, second.banked),
            databaseURL: db
        )
        XCTAssertTrue(third.deltas.isEmpty)
    }

    // MARK: Cline

    private func writeClineMessages(_ messages: [String], to url: URL) {
        let doc = "{\"messages\":[\(messages.joined(separator: ","))]}"
        try? Data(doc.utf8).write(to: url)
    }

    private func clineMessage(
        id: String?, tsMs: Int64, model: String = "claude-sonnet-4",
        input: Int, output: Int, cacheRead: Int, cacheWrite: Int
    ) -> String {
        let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {\(idField)"role":"assistant","ts":\(tsMs),\
        "modelInfo":{"id":"\(model)","provider":"anthropic"},\
        "metrics":{"inputTokens":\(input),"outputTokens":\(output),\
        "cacheReadTokens":\(cacheRead),"cacheWriteTokens":\(cacheWrite),"cost":0}}
        """
    }

    func testClineScanRewrittenDocumentKeepsLatestWithoutDoubleCounting() throws {
        let dataDir = temporaryRoot.appendingPathComponent("data", isDirectory: true)
        let sessionsDir = dataDir.appendingPathComponent("sessions/ses-1", isDirectory: true)
        let dbDir = dataDir.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let messagesURL = sessionsDir.appendingPathComponent("messages.json")

        // The session index db lists the file rather than being globbed.
        let dbURL = dbDir.appendingPathComponent("sessions.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            handle, "CREATE TABLE sessions (messages_path TEXT);", nil, nil, nil
        ), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            handle,
            "INSERT INTO sessions (messages_path) VALUES ('\(messagesURL.path)');",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(handle)

        let dirs: (data: URL, database: URL, sessions: URL) = (
            dataDir, dbURL, dataDir.appendingPathComponent("sessions", isDirectory: true)
        )

        writeClineMessages([
            #"{"id":"u1","role":"user","ts":1774900000000}"#,
            clineMessage(id: "m1", tsMs: 1_774_900_001_000,
                         input: 100, output: 40, cacheRead: 10, cacheWrite: 5),
        ], to: messagesURL)

        let first = TokenScanners.scanCline(watermarks: [:], banked: [:], directories: dirs)
        XCTAssertEqual(first.deltas.count, 1)
        XCTAssertEqual(first.deltas.first?.provider, "cline")
        XCTAssertEqual(first.deltas.first?.model, "claude-sonnet-4")
        XCTAssertEqual(totals(first).freshInput, 100)
        XCTAssertEqual(totals(first).cacheRead, 10)
        XCTAssertEqual(totals(first).cacheWrite5m, 5)
        XCTAssertEqual(totals(first).output, 40)

        // A rewrite restates m1 with grown metrics and adds m2; only the
        // growth and the new message count.
        writeClineMessages([
            clineMessage(id: "m1", tsMs: 1_774_900_001_000,
                         input: 120, output: 60, cacheRead: 10, cacheWrite: 5),
            clineMessage(id: "m2", tsMs: 1_774_900_002_000,
                         input: 30, output: 12, cacheRead: 0, cacheWrite: 0),
        ], to: messagesURL)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: messagesURL.path
        )

        let second = TokenScanners.scanCline(
            watermarks: first.watermarks, banked: first.banked, directories: dirs
        )
        XCTAssertEqual(totals(second).freshInput, 20 + 30)
        XCTAssertEqual(totals(second).output, 20 + 12)
        XCTAssertEqual(totals(second).cacheRead, 0)

        let third = TokenScanners.scanCline(
            watermarks: second.watermarks,
            banked: mergeBanked(first.banked, second.banked),
            directories: dirs
        )
        XCTAssertTrue(third.deltas.isEmpty)
    }

    // MARK: Qwen Code

    private func qwenRuntimeRoot() throws -> URL {
        let chats = temporaryRoot
            .appendingPathComponent("qwen-runtime/projects/proj-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        return temporaryRoot.appendingPathComponent("qwen-runtime", isDirectory: true)
    }

    func testQwenScanCountsAssistantDedupesUUIDsAndSkipsTelemetry() throws {
        let runtime = try qwenRuntimeRoot()
        let chats = runtime.appendingPathComponent("projects/proj-1/chats", isDirectory: true)

        let main = """
        {"uuid":"u1","parentUuid":null,"timestamp":"2026-09-22T10:00:00.000Z","type":"user"}
        {"uuid":"a1","parentUuid":"u1","timestamp":"2026-09-22T10:00:01.000Z","type":"assistant","model":"qwen3-coder","usageMetadata":{"promptTokenCount":1000,"cachedContentTokenCount":400,"candidatesTokenCount":150,"thoughtsTokenCount":30}}
        {"uuid":"s1","timestamp":"2026-09-22T10:00:02.000Z","type":"system","subtype":"ui_telemetry","usageMetadata":{"promptTokenCount":99999,"cachedContentTokenCount":0,"candidatesTokenCount":99999,"thoughtsTokenCount":0}}
        """
        try Data((main + "\n").utf8).write(to: chats.appendingPathComponent("main.jsonl"))

        // /branch copies records verbatim: a1 repeats with the same uuid.
        let branch = """
        {"uuid":"a1","parentUuid":"u1","timestamp":"2026-09-22T10:00:01.000Z","type":"assistant","model":"qwen3-coder","usageMetadata":{"promptTokenCount":1000,"cachedContentTokenCount":400,"candidatesTokenCount":150,"thoughtsTokenCount":30}}
        {"uuid":"a2","parentUuid":"a1","timestamp":"2026-09-22T10:05:00.000Z","type":"assistant","model":"qwen3-coder","usageMetadata":{"promptTokenCount":500,"cachedContentTokenCount":0,"candidatesTokenCount":80,"thoughtsTokenCount":10}}
        """
        try Data((branch + "\n").utf8).write(to: chats.appendingPathComponent("branch.jsonl"))

        let output = TokenScanners.scanQwen(watermarks: [:], banked: [:], roots: [runtime])
        XCTAssertEqual(Set(output.deltas.map(\.provider)), ["qwen"])
        // promptTokenCount includes the cached share; thoughts ride as reasoning.
        XCTAssertEqual(totals(output).freshInput, 600 + 500)
        XCTAssertEqual(totals(output).cacheRead, 400)
        XCTAssertEqual(totals(output).output, 150 + 80)
        XCTAssertEqual(totals(output).reasoning, 30 + 10)

        // Rescan: banked uuids keep the branch copy from counting again.
        let second = TokenScanners.scanQwen(
            watermarks: output.watermarks, banked: output.banked, roots: [runtime]
        )
        XCTAssertTrue(second.deltas.isEmpty)
    }
}

final class NanoISO8601Tests: XCTestCase {
    func testFastPathMatchesTheFormatter() {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let date = Date(timeIntervalSince1970: Double.random(in: 0...4_102_444_800, using: &generator).rounded() + 0.25)
            for formatter in [precise, whole] {
                for zone in [TimeZone(identifier: "UTC")!, TimeZone(secondsFromGMT: 19_800)!, TimeZone(secondsFromGMT: -25_200)!] {
                    formatter.timeZone = zone
                    let text = formatter.string(from: date)
                    XCTAssertEqual(NanoISO8601.fast(text), formatter.date(from: text), text)
                }
            }
        }
        XCTAssertEqual(NanoISO8601.fast("2024-02-29T23:59:59.5Z"), precise.date(from: "2024-02-29T23:59:59.500Z"))
        XCTAssertEqual(NanoISO8601.fast("2026-10-22T19:04:05.123456Z")?.timeIntervalSince1970 ?? 0,
                       1_792_695_845.123456, accuracy: 0.000_001)
    }

    func testFastPathLeavesOddInputToTheFormatter() {
        for text in ["", "2026-10-22", "2026-10-22 19:04:05Z", "2026-13-01T00:00:00Z", "2026-10-22T19:04:05", "2026-10-22T19:04:05.Z", "2026-10-22T19:04:05+0530"] {
            XCTAssertNil(NanoISO8601.fast(text), text)
        }
        XCTAssertNotNil(NanoISO8601.date("2026-10-22T19:04:05Z"))
    }
}
