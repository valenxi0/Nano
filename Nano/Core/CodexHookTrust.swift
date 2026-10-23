import Foundation

// Codex only runs a hook while `config.toml` holds a `trusted_hash` matching
// the hook's current content. Any edit to `hooks.json` — Nano's own installer
// included — shifts the position-based keys and Codex silently skips the hook,
// which means approval cards never reach the island. Nano may re-approve its
// own bridge entries automatically; every other tool's trust stays the user's
// call, so the filter below is deliberately narrow.
enum CodexHookTrust {
    struct Repair: Equatable, Sendable {
        let key: String
        let hash: String
    }

    /// The untrusted entries Nano owns, taken from the `result` object of a
    /// `hooks/list` response. Keys repeat across cwds, so they dedupe here.
    static func repairs(inHooksList result: [String: Any], hooksFile: URL) -> [Repair] {
        guard let cwds = result["data"] as? [[String: Any]] else { return [] }
        let wantedPath = hooksFile.standardized.path
        var seen = Set<String>()
        var repairs: [Repair] = []
        for cwd in cwds {
            guard let hooks = cwd["hooks"] as? [[String: Any]] else { continue }
            for hook in hooks {
                guard let key = hook["key"] as? String, !seen.contains(key) else { continue }
                seen.insert(key)
                guard (hook["handlerType"] as? String) == "command",
                      (hook["command"] as? String)?.contains(AgentHookBridge.bridgeMarker) == true,
                      (hook["source"] as? String) == "user",
                      (hook["isManaged"] as? Bool) == false,
                      (hook["enabled"] as? Bool) == true,
                      let status = hook["trustStatus"] as? String,
                      status == "untrusted" || status == "modified",
                      let sourcePath = hook["sourcePath"] as? String,
                      URL(fileURLWithPath: sourcePath).standardized.path == wantedPath,
                      let hash = hook["currentHash"] as? String, !hash.isEmpty
                else { continue }
                repairs.append(Repair(key: key, hash: hash))
            }
        }
        return repairs
    }

    /// Params for `config/value/write`; upsert keeps trust entries belonging
    /// to other tools and to Nano's hooks that are still fine.
    static func trustWriteParams(_ repairs: [Repair]) -> [String: Any] {
        var value: [String: Any] = [:]
        for repair in repairs {
            value[repair.key] = ["trusted_hash": repair.hash]
        }
        return [
            "keyPath": "hooks.state",
            "mergeStrategy": "upsert",
            "value": value,
        ]
    }

    /// One short-lived app-server session: list, re-trust what needs it, quit.
    /// `nil` means the check failed and is worth retrying; `[]` means Codex
    /// answered and nothing Nano owns was untrusted. Either way the process is
    /// always terminated — a watcher must never leave a CLI behind.
    static func repairIfNeeded(hooksFile: URL = AgentHookBridge.codexHooksURL) -> [Repair]? {
        guard let executableURL = AgentCodexThreadNames.appServerExecutableURL() else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = ResponseCollector()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        environment["PATH"] = localBin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.consume(handle.availableData)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        do {
            try process.run()
            try write([
                "id": 1,
                "method": "initialize",
                "params": ["clientInfo": ["name": "nano", "version": "1"]],
            ], to: input.fileHandleForWriting)
            guard collector.wait(for: 1, timeout: 2) != nil else { return nil }
            try write(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
            try write([
                "id": 2,
                "method": "hooks/list",
                "params": ["cwds": [String]()],
            ], to: input.fileHandleForWriting)
            guard let list = collector.wait(for: 2, timeout: 5),
                  let result = list["result"] as? [String: Any]
            else { return nil }
            let repairs = repairs(inHooksList: result, hooksFile: hooksFile)
            guard !repairs.isEmpty else { return [] }
            try write([
                "id": 3,
                "method": "config/value/write",
                "params": trustWriteParams(repairs),
            ], to: input.fileHandleForWriting)
            guard let written = collector.wait(for: 3, timeout: 5),
                  (written["result"] as? [String: Any])?["status"] as? String == "ok"
            else { return nil }
            return repairs
        } catch {
            return nil
        }
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    /// Responses arrive interleaved with notifications, so each request waits
    /// on its own id rather than on the next line.
    private final class ResponseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var results: [Int: [String: Any]] = [:]
        private var signals: [Int: DispatchSemaphore] = [:]

        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            var pending: [(Int, DispatchSemaphore)] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (object["id"] as? NSNumber)?.intValue
                else { continue }
                results[id] = object
                if let semaphore = signals[id] { pending.append((id, semaphore)) }
            }
            lock.unlock()
            for (id, semaphore) in pending where results[id] != nil {
                semaphore.signal()
            }
        }

        func wait(for id: Int, timeout seconds: Double) -> [String: Any]? {
            let semaphore = lock.withLock {
                let s = signals[id] ?? DispatchSemaphore(value: 0)
                signals[id] = s
                // The response may have landed before the wait began.
                if results[id] != nil { s.signal() }
                return s
            }
            _ = semaphore.wait(timeout: .now() + seconds)
            return lock.withLock { results[id] }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
