import AppKit
import Darwin
import XCTest
@testable import Nano

/// Measures Quill's engines on this Mac through the same
/// `VoiceDictationController` path a hotkey release takes.
///
/// `NANO_VD_BENCHMARK_ENGINES` (comma-separated raw values, e.g.
/// `cohereTranscribe,whisperTurbo`) limits the run and its downloads.
///
/// Skipped unless `NANO_VD_BENCHMARK=1`: it downloads the models into
/// Nano's real model directory (the same files the app would use) and runs
/// for several minutes. Results are written to `$NANO_VD_BENCHMARK_OUT`
/// (default `/tmp/nano-vd/benchmark`).
@MainActor
final class VoiceDictationBenchmark: XCTestCase {
    private static let vocabulary: [VoiceDictationVocabularyEntry] = [
        .init(phrase: "north star", replacement: "Nano", kind: .vocabulary),
        .init(phrase: "kubernetes", replacement: "Kubernetes", kind: .vocabulary),
        .init(phrase: "insert sign off", replacement: "Best,\nAlex", kind: .snippet),
    ]

    private struct Utterance {
        let id: String
        let text: String
        var noiseSNR: Double? = nil
    }

    private static let utterances: [Utterance] = [
        .init(id: "short-command", text: "Open the calendar."),
        .init(
            id: "fillers-corrections",
            text: "Um, so I think we should, uh, ship it on Tuesday, no, Thursday, and, um, let the team know before the standup."
        ),
        .init(
            id: "numbers-dates-email",
            text: "My flight lands on March third at four thirty PM. Email me at alex dot rivera at example dot com, and the total came to two hundred forty five dollars."
        ),
        .init(
            id: "names-technical",
            text: "We migrated the Kubernetes cluster to Postgres sixteen, rewrote the SwiftUI view in Xcode, and asked Priya Ramaswamy to review it."
        ),
        .init(
            id: "vocabulary-snippet",
            text: "North Star now supports voice dictation on this Mac. Insert sign off."
        ),
        .init(
            id: "noisy-numbers",
            text: "Call me back at five five five, zero one nine eight, before the fourteenth.",
            noiseSNR: 12
        ),
        .init(
            id: "long-dictation",
            text: """
            Hi team, quick update on the notch companion work. Over the last week we finished the settings pane for voice dictation, wired the global hotkey through Carbon so it does not need accessibility permission, and moved model downloads onto a background task so the island never stalls. There are three engines to choose from, and none of them download unless you pick one. The default pairs Parakeet with S1 mini, which cleans up fillers and adds punctuation. Whisper base and Whisper tiny are there as fallbacks for smaller machines. History is off unless you turn it on, and when it is on, entries are removed after twenty four hours. Next up is the benchmark on the Mac mini, then a review pass on the failure states, and after that we can talk about shipping it in the next build. Let me know if anything here is unclear.
            """
        ),
    ]

    private var outputDirectory: URL!
    private var audioDirectory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var savedClipboard: String?
    private var report: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NANO_VD_BENCHMARK"] == "1",
            "Set NANO_VD_BENCHMARK=1 to run the engine benchmark."
        )
        let out = ProcessInfo.processInfo.environment["NANO_VD_BENCHMARK_OUT"] ?? "/tmp/nano-vd/benchmark"
        outputDirectory = URL(fileURLWithPath: out, isDirectory: true)
        audioDirectory = outputDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        suite = "nano-vd-benchmark-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        savedClipboard = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() async throws {
        if let defaults, let suite { defaults.removePersistentDomain(forName: suite) }
        if let savedClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(savedClipboard, forType: .string)
        }
        try await super.tearDown()
    }

    func testBenchmarkAllEngines() async throws {
        report["machine"] = Self.machineInfo()
        report["startedAt"] = ISO8601DateFormatter().string(from: Date())
        report["thermalStateBefore"] = Self.thermal(ProcessInfo.processInfo.thermalState)
        report["memoryPressureBefore"] = Self.memoryPressure()
        report["swapBefore"] = Self.swapUsage()

        let store = VoiceDictationModelStore(rootDirectory: VoiceDictationModelStore.defaultRootDirectory)
        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(true, for: .voiceDictation)
        settings.voiceDictationVocabulary = Self.vocabulary
        settings.voiceDictationHistoryEnabled = false
        let controller = VoiceDictationController(
            settings: settings,
            modelStore: store,
            history: VoiceDictationHistoryStore(fileURL: outputDirectory.appendingPathComponent("history.json")),
            stats: VoiceDictationStatsStore(fileURL: outputDirectory.appendingPathComponent("stats.json"))
        )
        controller.completionHoldInterval = .zero
        controller.failureHoldInterval = .zero
        controller.idleUnloadInterval = .seconds(3600)

        // --- Audio fixtures
        var clips: [String: [Float]] = [:]
        for utterance in Self.utterances {
            var samples = try synthesize(utterance)
            if let snr = utterance.noiseSNR { samples = Self.addNoise(to: samples, snrDB: snr) }
            clips[utterance.id] = samples
        }
        clips["silence"] = [Float](repeating: 0, count: 32_000)
        report["audio"] = clips.mapValues { ["seconds": Double($0.count) / VoiceDictationAudioRecorder.sampleRate] }
        XCTAssertFalse(VoiceDictationController.containsSpeech(clips["silence"]!))
        let longSeconds = Double(clips["long-dictation"]!.count) / VoiceDictationAudioRecorder.sampleRate
        XCTAssertGreaterThan(longSeconds, 30, "long dictation should be 30–60 s")

        // --- Downloads (non-blocking: the main-thread probe runs alongside)
        let probe = MainThreadProbe()
        probe.start()
        var downloads: [String: Any] = [:]
        let selected = Self.selectedEngines
        let models = VoiceDictationModelID.allCases.filter { id in
            selected.contains { $0.requiredModels.contains(id) || $0.optionalModels.contains(id) }
        }
        for id in models where !store.isInstalled(id) {
            let started = ContinuousClock.now
            store.download(id)
            while store.state(of: id).isDownloading || store.state(of: id) == .verifying {
                try await Task.sleep(for: .milliseconds(200))
            }
            let state = store.state(of: id)
            downloads[id.rawValue] = [
                "seconds": Self.seconds(started.duration(to: .now)),
                "state": "\(state)",
                "bytes": VoiceDictationModelManifest.descriptor(for: id).totalBytes,
            ]
            XCTAssertEqual(state, .downloaded, "\(id) download: \(state)")
        }
        downloads["mainThreadMaxStallMs"] = probe.stop() * 1000
        report["downloads"] = downloads
        for id in models {
            XCTAssertTrue(store.isInstalled(id), "\(id) must be installed to benchmark")
        }

        // --- Engines
        var engines: [String: Any] = [:]
        for engine in selected {
            engines[engine.rawValue] = try await benchmark(engine, controller: controller, clips: clips)
            controller.unloadEngines()
            try await Task.sleep(for: .seconds(2))
        }
        report["engines"] = engines

        report["thermalStateAfter"] = Self.thermal(ProcessInfo.processInfo.thermalState)
        report["memoryPressureAfter"] = Self.memoryPressure()
        report["swapAfter"] = Self.swapUsage()
        report["processLifetimePeakFootprintMB"] = Self.rusage().ri_lifetime_max_phys_footprint / (1 << 20)

        try write()
    }

    private static var selectedEngines: [VoiceDictationEngine] {
        guard let list = ProcessInfo.processInfo.environment["NANO_VD_BENCHMARK_ENGINES"], !list.isEmpty else {
            return VoiceDictationEngine.allCases
        }
        return list.split(separator: ",").compactMap {
            VoiceDictationEngine(rawValue: $0.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Per-engine

    private func benchmark(
        _ engine: VoiceDictationEngine,
        controller: VoiceDictationController,
        clips: [String: [Float]]
    ) async throws -> [String: Any] {
        controller.settings.voiceDictationEngine = engine
        var result: [String: Any] = ["accelerator": ""]

        // Cold: load + first transcription, measured separately from warm.
        let footprintBefore = Self.rusage().ri_phys_footprint
        let sampler = ResourceSampler()
        let probe = MainThreadProbe()
        sampler.start(); probe.start()
        let cold = await controller.processCapturedAudio(clips["short-command"]!, engine: engine)
        let coldStall = probe.stop()
        let coldSample = sampler.stop()
        switch cold {
        case .success(let value):
            result["cold"] = [
                "modelLoadS": value.metrics.modelLoad,
                "transcriptionS": value.metrics.transcription,
                "cleanupS": value.metrics.cleanup,
                "stopToClipboardS": value.metrics.stopToClipboard,
                "peakCPUCores": coldSample.peakCores,
                "mainThreadMaxStallMs": coldStall * 1000,
            ]
            result["accelerator"] = value.metrics.accelerator
            XCTAssertTrue(value.metrics.wasColdStart)
        case .failure(let error):
            result["cold"] = ["error": error.detail]
            XCTFail("\(engine) cold run failed: \(error.detail)")
            return result
        }
        result["footprintAfterLoadMB"] = (Self.rusage().ri_phys_footprint - footprintBefore) / (1 << 20)

        // Warm: three passes over every utterance.
        var runs: [[String: Any]] = []
        var stalls: [Double] = []
        var peakCores = 0.0
        var peakFootprint: UInt64 = 0
        for pass in 0 ..< 3 {
            for utterance in Self.utterances {
                let samples = clips[utterance.id]!
                sampler.start(); probe.start()
                let outcome = await controller.processCapturedAudio(samples, engine: engine)
                stalls.append(probe.stop())
                let usage = sampler.stop()
                peakCores = max(peakCores, usage.peakCores)
                peakFootprint = max(peakFootprint, usage.peakFootprint)
                var run: [String: Any] = [
                    "utterance": utterance.id, "pass": pass,
                    "audioS": Double(samples.count) / VoiceDictationAudioRecorder.sampleRate,
                ]
                switch outcome {
                case .success(let value):
                    XCTAssertFalse(value.metrics.wasColdStart, "\(engine) should be warm on pass \(pass)")
                    run["transcriptionS"] = value.metrics.transcription
                    run["cleanupS"] = value.metrics.cleanup
                    run["postProcessingS"] = value.metrics.postProcessing
                    run["stopToClipboardS"] = value.metrics.stopToClipboard
                    run["raw"] = value.rawTranscript
                    run["final"] = value.finalText
                    run["applied"] = value.appliedReplacements
                    XCTAssertEqual(NSPasteboard.general.string(forType: .string), value.finalText)
                case .failure(let error):
                    run["error"] = error.detail
                }
                runs.append(run)
            }
        }
        result["warmRuns"] = runs
        result["warm"] = Self.summarize(runs, longID: "long-dictation")
        result["mainThreadMaxStallMs"] = (stalls.max() ?? 0) * 1000
        result["peakCPUCores"] = peakCores
        result["peakFootprintMB"] = peakFootprint / (1 << 20)

        // Silence: the engine must not hallucinate text onto the clipboard.
        NSPasteboard.general.clearContents()
        let silence = await controller.processCapturedAudio(clips["silence"]!, engine: engine)
        switch silence {
        case .success(let value):
            result["silence"] = ["unexpectedText": value.finalText]
        case .failure(let error):
            result["silence"] = ["error": "\(error)"]
        }

        // Cancellation: in flight on the long clip, cancel after 150 ms.
        let cancelTask = Task { await controller.processCapturedAudio(clips["long-dictation"]!, engine: engine) }
        try await Task.sleep(for: .milliseconds(150))
        let cancelStart = ContinuousClock.now
        controller.cancel()
        let phaseAfterCancel = controller.phase
        _ = await cancelTask.value
        result["cancel"] = [
            "phaseImmediatelyAfterCancel": phaseAfterCancel.title,
            "backgroundWorkDrainedS": Self.seconds(cancelStart.duration(to: .now)),
        ]
        XCTAssertEqual(phaseAfterCancel, .cancelled, "cancel shows a brief acknowledgement, then idles")

        // Idle: no sustained CPU after work completes.
        try await Task.sleep(for: .seconds(1))
        let idle = ResourceSampler()
        idle.start()
        try await Task.sleep(for: .seconds(3))
        result["idleAvgCPUCores"] = idle.stop().averageCores
        return result
    }

    // MARK: - Fixtures

    /// Synthesizes 16 kHz mono PCM with the system voice. Synthetic speech is
    /// a stand-in for a human reading the same script; it is deterministic
    /// across runs, which is what a benchmark wants.
    private func synthesize(_ utterance: Utterance) throws -> [Float] {
        let url = audioDirectory.appendingPathComponent("\(utterance.id).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-o", url.path, "--data-format=LEI16@16000", utterance.text]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("`say` failed for \(utterance.id)")
            }
        }
        return try Self.readWAV(url)
    }

    private static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4 ..< offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if id == "data" {
                let body = data[offset + 8 ..< min(offset + 8 + size, data.count)]
                return body.withUnsafeBytes { raw -> [Float] in
                    let int16 = raw.bindMemory(to: Int16.self)
                    return int16.map { Float($0) / 32768 }
                }
            }
            offset += 8 + size + (size & 1)
        }
        throw XCTSkip("no data chunk in \(url.lastPathComponent)")
    }

    private static func addNoise(to samples: [Float], snrDB: Double) -> [Float] {
        let power = samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)
        let noisePower = power / pow(10, snrDB / 10)
        let sigma = Float(noisePower.squareRoot())
        var generator = SystemRandomNumberGenerator()
        return samples.map { sample in
            // Box–Muller
            let u1 = max(Float.random(in: 0 ..< 1, using: &generator), 1e-7)
            let u2 = Float.random(in: 0 ..< 1, using: &generator)
            let gaussian = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            return max(-1, min(1, sample + gaussian * sigma))
        }
    }

    // MARK: - Stats

    private static func summarize(_ runs: [[String: Any]], longID: String) -> [String: Any] {
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let rank = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[rank]
        }
        func block(_ subset: [[String: Any]]) -> [String: Any] {
            let stc = subset.compactMap { $0["stopToClipboardS"] as? Double }
            let tr = subset.compactMap { $0["transcriptionS"] as? Double }
            let cl = subset.compactMap { $0["cleanupS"] as? Double }
            return [
                "n": stc.count,
                "failures": subset.count - stc.count,
                "stopToClipboardP50S": percentile(stc, 0.5),
                "stopToClipboardP95S": percentile(stc, 0.95),
                "stopToClipboardMaxS": stc.max() ?? 0,
                "transcriptionMeanS": tr.isEmpty ? 0 : tr.reduce(0, +) / Double(tr.count),
                "cleanupMeanS": cl.isEmpty ? 0 : cl.reduce(0, +) / Double(cl.count),
            ]
        }
        let short = runs.filter { ($0["utterance"] as? String) != longID }
        let long = runs.filter { ($0["utterance"] as? String) == longID }
        let firstPass = short.filter { ($0["pass"] as? Int) == 0 }.compactMap { $0["stopToClipboardS"] as? Double }
        let lastPass = short.filter { ($0["pass"] as? Int) == 2 }.compactMap { $0["stopToClipboardS"] as? Double }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return [
            "typical": block(short),
            "longDictation": block(long),
            "all": block(runs),
            "degradationFirstToLastPassPct": firstPass.isEmpty ? 0 : (mean(lastPass) - mean(firstPass)) / mean(firstPass) * 100,
        ]
    }

    // MARK: - Machine

    private static func machineInfo() -> [String: Any] {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buffer = [UInt8](repeating: 0, count: size)
            sysctlbyname(name, &buffer, &size, nil, 0)
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        func sysctlInt(_ name: String) -> Int64 {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            sysctlbyname(name, &value, &size, nil, 0)
            return value
        }
        return [
            "chip": sysctlString("machdep.cpu.brand_string"),
            "model": sysctlString("hw.model"),
            "performanceCores": sysctlInt("hw.perflevel0.logicalcpu"),
            "efficiencyCores": sysctlInt("hw.perflevel1.logicalcpu"),
            "memoryGB": Double(sysctlInt("hw.memsize")) / Double(1 << 30),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "inferenceThreads": VoiceDictationEngineFactory.inferenceThreads,
        ]
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func memoryPressure() -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        return value
    }

    private static func swapUsage() -> [String: Any] {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return ["usedMB": usage.xsu_used / (1 << 20), "totalMB": usage.xsu_total / (1 << 20)]
    }

    nonisolated static func rusage() -> rusage_info_v4 {
        var info = rusage_info_v4()
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                _ = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return info
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// `ri_user_time`/`ri_system_time` are Mach absolute-time ticks, not
    /// nanoseconds (on Apple silicon a tick is 1/24 µs).
    nonisolated static func cpuSeconds(_ usage: rusage_info_v4) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(usage.ri_user_time + usage.ri_system_time)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    private func write() throws {
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outputDirectory.appendingPathComponent("results.json"))
        print("NANO_VD_BENCHMARK_RESULTS=\(outputDirectory.appendingPathComponent("results.json").path)")
    }
}

/// Samples this process's CPU time and physical footprint at 50 ms cadence.
private final class ResourceSampler: @unchecked Sendable {
    struct Summary {
        var peakCores: Double = 0
        var averageCores: Double = 0
        var peakFootprint: UInt64 = 0
    }

    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private var summary = Summary()
    private var startCPU: Double = 0
    private var startWall: ContinuousClock.Instant = .now

    func start() {
        lock.withLock {
            summary = Summary()
            running = true
            startCPU = VoiceDictationBenchmark.cpuSeconds(VoiceDictationBenchmark.rusage())
            startWall = .now
        }
        let thread = Thread { [weak self] in
            var lastCPU = VoiceDictationBenchmark.rusage()
            var lastTime = ContinuousClock.now
            while self?.isRunning == true {
                Thread.sleep(forTimeInterval: 0.05)
                let usage = VoiceDictationBenchmark.rusage()
                let now = ContinuousClock.now
                let cpuDelta = VoiceDictationBenchmark.cpuSeconds(usage) - VoiceDictationBenchmark.cpuSeconds(lastCPU)
                let wall = VoiceDictationBenchmark.seconds(lastTime.duration(to: now))
                self?.record(cores: wall > 0 ? cpuDelta / wall : 0, footprint: usage.ri_phys_footprint)
                lastCPU = usage
                lastTime = now
            }
        }
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func record(cores: Double, footprint: UInt64) {
        lock.withLock {
            summary.peakCores = max(summary.peakCores, cores)
            summary.peakFootprint = max(summary.peakFootprint, footprint)
        }
    }

    func stop() -> Summary {
        lock.withLock {
            running = false
            let cpu = VoiceDictationBenchmark.cpuSeconds(VoiceDictationBenchmark.rusage()) - startCPU
            let wall = VoiceDictationBenchmark.seconds(startWall.duration(to: .now))
            summary.averageCores = wall > 0 ? cpu / wall : 0
            return summary
        }
    }
}

/// Ticks on the main actor every 16 ms and records the worst overshoot: the
/// longest stretch the main thread was unavailable.
@MainActor
private final class MainThreadProbe {
    private var task: Task<Void, Never>?
    private var worst: Double = 0

    func start() {
        worst = 0
        task = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = ContinuousClock.now
                let gap = VoiceDictationBenchmark.seconds(last.duration(to: now)) - 0.016
                if let self, gap > self.worst { self.worst = gap }
                last = now
            }
        }
    }

    /// Returns the worst stall in seconds.
    func stop() -> Double {
        task?.cancel()
        task = nil
        return max(0, worst)
    }
}
