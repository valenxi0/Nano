import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sketch: talk while marking up the screen, and paste the screenshots with
/// what was said at each one, timestamped. The idea comes from Scrawl by Kit
/// Langton (github.com/kitlangton/scrawl, MIT).

/// One ink stroke, in global AppKit points (origin bottom-left, y up).
struct VoiceDictationSketchStroke: Sendable, Equatable {
    var points: [CGPoint]
    /// Recorder sample index when the stroke began: its time, and where it
    /// falls in the transcript.
    var startSample: Int
    var number: Int
}

/// Strokes drawn on one unchanged screen share a screenshot.
struct VoiceDictationSketchFrame: Sendable {
    var image: CGImage?
    var strokes: [VoiceDictationSketchStroke]
    var place = VoiceDictationSketchPlace()

    /// When the screenshot's first mark was drawn; zero without marks.
    var startSample: Int { strokes.map(\.startSample).min() ?? 0 }
}

/// Where a moment happened: the app in front, its window title, and for a
/// click, the element under the pointer.
struct VoiceDictationSketchPlace: Sendable, Equatable {
    var app: String?
    var window: String?
    var element: String?

    /// "in Safari “GitHub”", or nil when nothing is known.
    var description: String? {
        guard let app else { return nil }
        guard let window = window?.trimmingCharacters(in: .whitespaces), !window.isEmpty, window != app else {
            return "in \(app)"
        }
        return "in \(app) “\(window.count > 60 ? String(window.prefix(59)) + "…" : window)”"
    }
}

/// A screenshot worth keeping from the recording, and why.
struct VoiceDictationSketchMoment: Sendable {
    enum Kind: Int, Sendable, Comparable {
        /// The screen when recording began.
        case start
        /// The screen changed and then held still.
        case change
        /// A click; the screenshot is what was clicked.
        case click
        /// One or more marks drawn on the same screen.
        case marks

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var kind: Kind
    /// Recorder sample index of the moment.
    var sample: Int
    var image: CGImage
    var strokes: [VoiceDictationSketchStroke] = []
    /// Where a click landed, in global AppKit points.
    var click: CGPoint?
    var place = VoiceDictationSketchPlace()

    var tag: String? {
        switch kind {
        case .click: place.element.map { "[clicked \($0)]" } ?? "[clicked]"
        case .change: "[screen changed]"
        case .start, .marks: nil
        }
    }
}

/// One place in the speech: where a screenshot begins, or a numbered mark
/// within one.
struct VoiceDictationSketchAnchor: Sendable, Equatable {
    var sample: Int
    var frame: Int
    var label: String?
}

/// Where the recording is cut so each anchor lands between words. `marks`
/// are indexes into the anchors.
struct VoiceDictationSketchCut: Sendable, Equatable {
    var sample: Int
    var marks: [Int]
}

/// Picks the screenshots to send, like Scrawl: every mark, then clicks, then
/// settled screen changes, within a budget that grows with the length of the
/// recording. A screenshot that looks like its neighbour adds nothing and is
/// dropped, unless it carries marks.
enum VoiceDictationSketchPicker {
    nonisolated static func budget(seconds: Double) -> Int {
        min(10, 6 + max(0, Int((seconds - 40) / 20)))
    }

    /// Below this share of changed grid cells, two screenshots are the same.
    nonisolated static let sameScreenShare: Float = 0.03

    nonisolated static func pick(
        _ moments: [VoiceDictationSketchMoment],
        seconds: Double,
        grid: (CGImage) -> [Float] = VoiceDictationSketchRecorder.grid(of:)
    ) -> [VoiceDictationSketchMoment] {
        var kept = moments.sorted { $0.sample < $1.sample }
        let grids = Dictionary(uniqueKeysWithValues: kept.indices.map { ($0, grid(kept[$0].image)) })
        var keptGrids = kept.indices.map { grids[$0]! }

        // Drop repeats of the same screen, keeping the more telling one.
        var index = 1
        while index < kept.count {
            let same = VoiceDictationSketchRecorder.share(
                changedBetween: keptGrids[index - 1], and: keptGrids[index], by: 0.06
            ) < sameScreenShare
            if same, kept[index - 1].kind != .marks || kept[index].kind != .marks {
                let drop = kept[index - 1].kind >= kept[index].kind ? index : index - 1
                kept.remove(at: drop)
                keptGrids.remove(at: drop)
            } else {
                index += 1
            }
        }

        // Over budget: drop the least telling, closest to a neighbour first.
        let budget = max(budget(seconds: seconds), kept.filter { $0.kind == .marks }.count)
        while kept.count > budget {
            let candidates = kept.indices.filter { kept[$0].kind != .marks }
            guard let lowest = candidates.map({ kept[$0].kind }).min() else { break }
            let drop = candidates.filter { kept[$0].kind == lowest }.min { a, b in
                gap(kept, a) < gap(kept, b)
            }!
            kept.remove(at: drop)
        }
        return kept
    }

    private static func gap(_ moments: [VoiceDictationSketchMoment], _ index: Int) -> Int {
        let before = index > 0 ? moments[index].sample - moments[index - 1].sample : Int.max
        let after = index + 1 < moments.count ? moments[index + 1].sample - moments[index].sample : Int.max
        return min(before, after)
    }

    /// One anchor per screenshot, and one per mark when a screenshot has
    /// several, so the text can say [1] [2] where each was drawn.
    nonisolated static func anchors(for moments: [VoiceDictationSketchMoment]) -> [VoiceDictationSketchAnchor] {
        moments.enumerated().flatMap { index, moment -> [VoiceDictationSketchAnchor] in
            guard moment.strokes.count > 1 else {
                return [VoiceDictationSketchAnchor(sample: moment.sample, frame: index, label: nil)]
            }
            return moment.strokes.enumerated().map { number, stroke in
                VoiceDictationSketchAnchor(sample: stroke.startSample, frame: index, label: "[\(number + 1)]")
            }
        }
    }
}

enum VoiceDictationSketchText {
    /// A mark is placed at the quietest pause from this long before its
    /// stroke to shortly after, so it lands at the start of the clause being
    /// said rather than inside a word.
    nonisolated static let lookBackSeconds = 1.5
    nonisolated static let lookAheadSeconds = 0.3
    /// Marks this close together read as one place in the speech.
    nonisolated static let mergeSeconds = 0.4

    nonisolated static func cuts(
        marks: [(number: Int, sample: Int)],
        samples: [Float]
    ) -> [VoiceDictationSketchCut] {
        let rate = VoiceDictationAudioRecorder.sampleRate
        let back = Int(rate * lookBackSeconds)
        let ahead = Int(rate * lookAheadSeconds)
        let merge = Int(rate * mergeSeconds)
        let edge = Int(rate * 0.2)
        var cuts: [VoiceDictationSketchCut] = []
        for mark in marks.sorted(by: { $0.sample < $1.sample }) {
            let target = min(max(mark.sample, 0), samples.count)
            let range = max(0, target - back) ..< min(samples.count, target + ahead)
            var sample = VoiceDictationAudioSegmenter.pause(in: samples, range: range) ?? target
            if sample < edge { sample = 0 }
            if samples.count - sample < edge { sample = samples.count }
            if let last = cuts.last {
                if sample - last.sample < merge {
                    cuts[cuts.count - 1].marks.append(mark.number)
                    continue
                }
                sample = max(sample, last.sample)
            }
            cuts.append(VoiceDictationSketchCut(sample: sample, marks: [mark.number]))
        }
        return cuts
    }

    /// The audio between cuts, one piece more than there are cuts.
    nonisolated static func pieces(of samples: [Float], at cuts: [VoiceDictationSketchCut]) -> [[Float]] {
        var pieces: [[Float]] = []
        var start = 0
        for cut in cuts {
            let end = min(max(cut.sample, start), samples.count)
            pieces.append(Array(samples[start ..< end]))
            start = end
        }
        pieces.append(Array(samples[start...]))
        return pieces
    }

    /// One line per screenshot: its number, when it was taken, what
    /// happened, and what was said from then until the next one. Words said
    /// before the first screenshot belong to it.
    nonisolated static func compose(
        pieces: [String],
        cuts: [VoiceDictationSketchCut],
        anchors: [VoiceDictationSketchAnchor],
        frames: [(time: Double, tag: String?, place: String?)]
    ) -> String {
        guard !frames.isEmpty else {
            return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        var lines: [[String]] = Array(repeating: [], count: frames.count)
        var current = 0
        var previous = ""
        for (index, raw) in pieces.enumerated() {
            if index > 0 {
                for anchorIndex in cuts[index - 1].marks where anchorIndex < anchors.count {
                    let anchor = anchors[anchorIndex]
                    if anchor.frame != current {
                        current = anchor.frame
                        previous = ""
                    }
                    if let label = anchor.label { lines[current].append(label) }
                }
            }
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if continuesSentence(previous) { text = lowercasingFirstWord(text) }
            lines[current].append(text)
            previous = text
        }
        var lastPlace: String?
        return frames.enumerated().map { index, frame in
            var head = "- #\(index + 1) (\(clock(frame.time)))"
            // Where it happened, only when it moved since the line before.
            if let place = frame.place, place != lastPlace {
                head += " " + place
                lastPlace = place
            }
            if let tag = frame.tag { head += " " + tag }
            let said = lines[index].joined(separator: " ")
            return said.isEmpty ? head : "\(head) “\(said)”"
        }.joined(separator: "\n")
    }

    nonisolated static func header(
        duration: Double,
        folder: URL?,
        hasVideo: Bool = false,
        display: (points: CGSize, scale: CGFloat)? = nil
    ) -> String {
        var line = "[Sketch \(clock(duration))"
        if let display {
            line += " · \(Int(display.points.width))×\(Int(display.points.height)) pt display at \(Int(display.scale))x"
        }
        if let folder { line += " · \(hasVideo ? "video and screenshots" : "screenshots") in \(folder.path)" }
        return line + "]"
    }

    /// Read first by an agent that has no idea what a Sketch is.
    nonisolated static let preamble = "Screen markup from Nano Sketch. The screenshots are attached in order, numbered like the lines below, and zoomed crops follow each marked one. Each line is what I said while that screenshot was on screen; red ink is mine."

    nonisolated static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    nonisolated private static func continuesSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return !".!?:…".contains(last)
    }

    /// "This" becomes "this"; "I", "NASA" and "McDonald" stay.
    nonisolated private static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix { !$0.isWhitespace && $0 != "," && $0 != "." }
        guard word.count > 1, let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy({ !$0.isUppercase }),
              !word.hasPrefix("I'"), !word.hasPrefix("I’")
        else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Draws a screenshot's ink, its "#N 0:15" badge and mark numbers.
enum VoiceDictationSketchRenderer {
    nonisolated static let maximumLongEdge: CGFloat = 2048
    nonisolated static let inkColor = CGColor(red: 1, green: 0.231, blue: 0.188, alpha: 1)
    nonisolated static let inkWidth: CGFloat = 4

    nonisolated static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 1 ..< points.count {
            let previous = points[index - 1]
            let point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// `screenFrame` is the captured display in global AppKit points.
    nonisolated static func render(
        _ image: CGImage,
        strokes: [VoiceDictationSketchStroke],
        screenFrame: CGRect,
        click: CGPoint? = nil,
        badge: String? = nil
    ) -> CGImage? {
        let longEdge = CGFloat(max(image.width, image.height))
        let fit = min(1, maximumLongEdge / longEdge)
        let width = Int((CGFloat(image.width) * fit).rounded())
        let height = Int((CGFloat(image.height) * fit).rounded())
        guard width > 0, height > 0, let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Points to output pixels. AppKit and Core Graphics both put the
        // origin bottom-left, so no flip.
        let scale = CGFloat(width) / screenFrame.width
        let unit = max(1, scale)
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - screenFrame.minX) * scale, y: (point.y - screenFrame.minY) * scale)
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(inkColor)
        context.setLineWidth(inkWidth * unit)
        for stroke in strokes where stroke.points.count > 1 {
            context.addPath(smoothPath(stroke.points.map(pixel)))
            context.strokePath()
        }
        if strokes.count > 1 {
            for (index, stroke) in strokes.enumerated() {
                guard let start = stroke.points.first else { continue }
                drawMarkNumber(index + 1, near: pixel(start), unit: unit, in: context, size: CGSize(width: width, height: height))
            }
        }
        if let click {
            // A click is drawn apart from ink: a white ring with a dark edge.
            let center = pixel(click)
            let radius = 16 * unit
            let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setLineWidth(5 * unit)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            context.strokeEllipse(in: ring)
            context.setLineWidth(3 * unit)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.strokeEllipse(in: ring)
            context.setFillColor(CGColor(gray: 1, alpha: 0.95))
            context.fillEllipse(in: CGRect(x: center.x - 3 * unit, y: center.y - 3 * unit, width: 6 * unit, height: 6 * unit))
        }
        if let badge {
            var ink = strokes.flatMap { $0.points.map(pixel) }
            if let click { ink.append(pixel(click)) }
            drawBadge(badge, unit: unit, avoiding: ink, in: context, size: CGSize(width: width, height: height))
        }
        return context.makeImage()
    }

    /// The part of a rendered screenshot around some ink, at least 720 px
    /// wide, so an agent sees what was marked and not only where.
    nonisolated static func crop(
        _ rendered: CGImage,
        around points: [CGPoint],
        screenFrame: CGRect
    ) -> CGImage? {
        guard let first = points.first else { return nil }
        let scale = CGFloat(rendered.width) / screenFrame.width
        var box = CGRect(origin: first, size: .zero)
        for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
        // Points (y up) to image pixels (y down, as cropping expects).
        var pixels = CGRect(
            x: (box.minX - screenFrame.minX) * scale,
            y: (screenFrame.maxY - box.maxY) * scale,
            width: box.width * scale,
            height: box.height * scale
        )
        let minimum = min(720, CGFloat(rendered.width))
        let width = max(minimum, pixels.width * 1.6)
        let height = max(minimum * 0.6, pixels.height * 1.6)
        pixels = CGRect(x: pixels.midX - width / 2, y: pixels.midY - height / 2, width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        pixels.origin.x = min(max(pixels.minX, 0), bounds.width - min(width, bounds.width))
        pixels.origin.y = min(max(pixels.minY, 0), bounds.height - min(height, bounds.height))
        let clipped = pixels.intersection(bounds).integral
        // A crop that is nearly the whole screen adds nothing.
        guard clipped.width < bounds.width * 0.7 || clipped.height < bounds.height * 0.7 else { return nil }
        return rendered.cropping(to: clipped)
    }

    /// Several screenshots in one image, two to a row, so an agent reads them
    /// in one attachment. One screenshot is returned as it is.
    nonisolated static func contactSheet(_ images: [CGImage], maximumWidth: CGFloat = 2400) -> CGImage? {
        guard images.count > 1 else { return images.first }
        let columns = 2
        let gutter: CGFloat = 8
        let cellWidth = ((maximumWidth - gutter * CGFloat(columns + 1)) / CGFloat(columns)).rounded(.down)
        let cells = images.map { image -> CGSize in
            CGSize(width: cellWidth, height: (cellWidth * CGFloat(image.height) / CGFloat(image.width)).rounded())
        }
        var rowHeights: [CGFloat] = []
        for row in stride(from: 0, to: images.count, by: columns) {
            rowHeights.append(cells[row ..< min(row + columns, cells.count)].map(\.height).max() ?? 0)
        }
        let width = Int(maximumWidth)
        let height = Int(rowHeights.reduce(gutter) { $0 + $1 + gutter })
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var top = CGFloat(height) - gutter
        for (rowIndex, rowHeight) in rowHeights.enumerated() {
            for column in 0 ..< columns {
                let index = rowIndex * columns + column
                guard index < images.count else { break }
                let size = cells[index]
                let x = gutter + CGFloat(column) * (cellWidth + gutter)
                context.draw(images[index], in: CGRect(x: x, y: top - size.height, width: size.width, height: size.height))
            }
            top -= rowHeight + gutter
        }
        return context.makeImage()
    }

    nonisolated private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    nonisolated private static func line(_ text: String, size: CGFloat, color: CGColor) -> CTLine? {
        guard let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// "#1 0:15" in the top-left corner, or top-right when ink is there.
    nonisolated private static func drawBadge(
        _ text: String,
        unit: CGFloat,
        avoiding ink: [CGPoint],
        in context: CGContext,
        size: CGSize
    ) {
        guard let line = line(text, size: 15 * unit, color: CGColor(gray: 1, alpha: 1)) else { return }
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = CGSize(width: 10 * unit, height: 6 * unit)
        let box = CGSize(width: bounds.width + padding.width * 2, height: bounds.height + padding.height * 2)
        let margin = 14 * unit
        var origin = CGPoint(x: margin, y: size.height - margin - box.height)
        let left = CGRect(origin: origin, size: box).insetBy(dx: -margin, dy: -margin)
        if ink.contains(where: left.contains) {
            origin.x = size.width - margin - box.width
        }
        let rect = CGRect(origin: origin, size: box)
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.88))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: rect.minX + padding.width - bounds.minX, y: rect.minY + padding.height - bounds.minY)
        CTLineDraw(line, context)
    }

    nonisolated private static func drawMarkNumber(
        _ number: Int,
        near point: CGPoint,
        unit: CGFloat,
        in context: CGContext,
        size: CGSize
    ) {
        let radius = 11 * unit
        // Up and to the left of where the stroke began, kept on the image.
        let center = CGPoint(
            x: min(max(point.x - 14 * unit, radius + 2), size.width - radius - 2),
            y: min(max(point.y + 14 * unit, radius + 2), size.height - radius - 2)
        )
        context.setFillColor(inkColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        guard let line = line("\(number)", size: (number > 9 ? 11 : 13) * unit, color: CGColor(gray: 1, alpha: 1)) else { return }
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Saved screenshots live under Caches, whose path has no spaces, so a
/// terminal agent can take a pasted path as an image attachment.
enum VoiceDictationSketchStorage {
    nonisolated static let keepDays = 1.0

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nano", isDirectory: true)
            .appendingPathComponent("Sketches", isDirectory: true)
    }

    struct Saved: Sendable {
        var folder: URL
        var sheet: URL
        /// In the order given.
        var images: [URL]
        var video: URL?
    }

    /// Writes `sheet.png` and the named images into a new folder.
    nonisolated static func save(
        sheet: Data,
        images: [(name: String, data: Data)],
        video: URL? = nil,
        at date: Date = Date()
    ) throws -> Saved {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = directory.appendingPathComponent("sketch-\(formatter.string(from: date))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        purge(olderThan: date.addingTimeInterval(-keepDays * 86_400))
        let sheetURL = folder.appendingPathComponent("sheet.png")
        try sheet.write(to: sheetURL, options: .atomic)
        let imageURLs = try images.map { image in
            let url = folder.appendingPathComponent(image.name)
            try image.data.write(to: url, options: .atomic)
            return url
        }
        var videoURL: URL?
        if let video {
            let destination = folder.appendingPathComponent("recording.mp4")
            if (try? FileManager.default.moveItem(at: video, to: destination)) != nil { videoURL = destination }
        }
        return Saved(folder: folder, sheet: sheetURL, images: imageURLs, video: videoURL)
    }

    nonisolated static func purge(olderThan cutoff: Date) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }
        for folder in folders where folder.hasDirectoryPath || folder.pathExtension == "mp4" {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < cutoff { try? manager.removeItem(at: folder) }
        }
    }
}
