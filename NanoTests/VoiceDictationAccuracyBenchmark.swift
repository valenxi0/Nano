import AppKit
import AVFoundation
import XCTest
@testable import Nano

/// Word error rate on real voices, per engine.
///
/// Put recordings in `$NANO_VD_ACCURACY_DIR` (default
/// `~/Library/Application Support/Nano/VoiceDictation/Eval`): `name.wav` (or
/// .m4a/.aiff, any rate) next to `name.txt` with what was actually said.
/// Then run with `NANO_VD_ACCURACY=1`. Only installed engines are measured;
/// `NANO_VD_BENCHMARK_ENGINES` narrows the list. Results go to
/// `/tmp/nano-vd/accuracy/results.json`.
///
/// Raw WER scores the recognizer alone; final WER scores what would be
/// pasted, after cleanup and formatting. Both ignore case and punctuation.
@MainActor
final class VoiceDictationAccuracyBenchmark: XCTestCase {
    func testWordErrorRateMatchesTheTextbookDefinition() {
        XCTAssertEqual(WordErrorRate.score(reference: "the cat sat", hypothesis: "the cat sat"), 0)
        XCTAssertEqual(WordErrorRate.score(reference: "the cat sat", hypothesis: "the bat sat"), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(WordErrorRate.score(reference: "the cat sat", hypothesis: "the cat"), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(WordErrorRate.score(reference: "Hello, World!", hypothesis: "hello world"), 0)
        XCTAssertEqual(WordErrorRate.score(reference: "a b", hypothesis: "x a b y"), 1.0, accuracy: 1e-9)
    }

    func testRealVoiceAccuracy() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NANO_VD_ACCURACY"] == "1",
            "Set NANO_VD_ACCURACY=1 with recordings in the eval folder."
        )
        let folder = ProcessInfo.processInfo.environment["NANO_VD_ACCURACY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? NanoStorage.root.appendingPathComponent("VoiceDictation/Eval", isDirectory: true)
        let clips = try Self.clips(in: folder)
        try XCTSkipIf(clips.isEmpty, "No recordings with transcripts in \(folder.path)")

        let suite = "nano-vd-accuracy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(true, for: .voiceDictation)
        settings.voiceDictationHistoryEnabled = false
        settings.voiceDictationInsightsEnabled = false
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nano-vd-accuracy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = VoiceDictationModelStore(rootDirectory: VoiceDictationModelStore.defaultRootDirectory)
        let controller = VoiceDictationController(
            settings: settings,
            modelStore: store,
            history: VoiceDictationHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            stats: VoiceDictationStatsStore(fileURL: scratch.appendingPathComponent("stats.json")),
            corrections: VoiceDictationCorrectionStore(fileURL: scratch.appendingPathComponent("corrections.json"))
        )
        controller.completionHoldInterval = .zero
        controller.failureHoldInterval = .zero
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            if let savedClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedClipboard, forType: .string)
            }
        }

        let requested = ProcessInfo.processInfo.environment["NANO_VD_BENCHMARK_ENGINES"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        let engines = VoiceDictationEngine.allCases.filter {
            store.isReady($0) && (requested?.contains($0.rawValue) ?? true)
        }
        try XCTSkipIf(engines.isEmpty, "No engine is installed")

        var report: [String: Any] = [:]
        for engine in engines {
            settings.voiceDictationEngine = engine
            var rows: [[String: Any]] = []
            var rawErrors = 0.0
            var finalErrors = 0.0
            var words = 0.0
            for clip in clips {
                let outcome = await controller.processCapturedAudio(clip.samples, engine: engine)
                let referenceWords = Double(WordErrorRate.words(clip.reference).count)
                switch outcome {
                case .success(let result):
                    let raw = WordErrorRate.score(reference: clip.reference, hypothesis: result.rawTranscript)
                    let final = WordErrorRate.score(reference: clip.reference, hypothesis: result.finalText)
                    rawErrors += raw * referenceWords
                    finalErrors += final * referenceWords
                    rows.append(["clip": clip.name, "rawWER": raw, "finalWER": final,
                                 "raw": result.rawTranscript, "final": result.finalText,
                                 "language": result.language ?? ""])
                case .failure(let error):
                    rawErrors += referenceWords
                    finalErrors += referenceWords
                    rows.append(["clip": clip.name, "error": error.detail])
                }
                words += referenceWords
            }
            report[engine.rawValue] = [
                "rawWER": words > 0 ? rawErrors / words : 0,
                "finalWER": words > 0 ? finalErrors / words : 0,
                "clips": rows,
            ]
            controller.unloadEngines()
        }

        let out = URL(fileURLWithPath: "/tmp/nano-vd/accuracy", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("results.json"))
    }

    private struct Clip {
        let name: String
        let samples: [Float]
        let reference: String
    }

    private static func clips(in folder: URL) throws -> [Clip] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return try files
            .filter { ["wav", "m4a", "aiff", "caf", "mp3"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio in
                let text = audio.deletingPathExtension().appendingPathExtension("txt")
                guard let reference = try? String(contentsOf: text, encoding: .utf8) else { return nil }
                return Clip(
                    name: audio.deletingPathExtension().lastPathComponent,
                    samples: try read16kMono(audio),
                    reference: reference
                )
            }
    }

    /// Any file AVFoundation can open, as 16 kHz mono Float32.
    private static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        final class Consumed: @unchecked Sendable { var value = false }
        let consumed = Consumed()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed.value {
                status.pointee = .endOfStream
                return nil
            }
            consumed.value = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// Word-level Levenshtein distance over the reference length.
enum WordErrorRate {
    static func words(_ text: String) -> [String] {
        let kept = text.lowercased().map { (character: Character) -> Character in
            character.isLetter || character.isNumber || character == "'" ? character : " "
        }
        return String(kept).split(separator: " ").map(String.init)
    }

    static func score(reference: String, hypothesis: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var previous = Array(0 ... hyp.count)
        for (i, r) in ref.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hyp.count)
            for (j, h) in hyp.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (r == h ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }
}
