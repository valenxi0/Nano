import AVFoundation
import CoreImage
import QuartzCore
import ScreenCaptureKit

/// Records one display, without Nano's windows, to an .mp4 while a Sketch
/// runs, and watches it for changes: when the screen changes and then holds
/// still, that settled screen is offered as a screenshot.
///
/// ScreenCaptureKit only delivers frames while something on screen moves, so
/// "settled" is decided by a timer, not by the next frame.
final class VoiceDictationSketchRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Change: Sendable {
        /// When the screen started changing, in `CACurrentMediaTime` seconds.
        var time: CFTimeInterval
        var image: CGImage
    }

    nonisolated static let framesPerSecond: Int32 = 15
    /// A screen counts as changed when this share of the grid moved.
    nonisolated static let changeShare: Float = 0.04
    /// And as settled after this long without movement.
    nonisolated static let settleSeconds: CFTimeInterval = 0.5

    let videoURL: URL
    /// Called on the main queue when a change settles, with when it began.
    var onChange: (@Sendable (CFTimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "com.nanoapp.Nano.sketch-recorder")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startedSession = false
    private var latest: CVPixelBuffer?
    private var reference: [Float]?
    private var previous: [Float]?
    private var changeStart: CFTimeInterval?
    private var lastMovement: CFTimeInterval = 0
    private var changes: [Change] = []
    private var timer: DispatchSourceTimer?

    init(videoURL: URL) {
        self.videoURL = videoURL
    }

    func start(displayID: CGDirectDisplayID, pixelSize: CGSize) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw VoiceDictationError.screenCaptureFailed
        }
        let nano = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: nano, exceptingWindows: [])
        // Big enough to read text in a screenshot, small enough to encode live.
        let fit = min(1, 2560 / max(pixelSize.width, pixelSize.height))
        let width = Int(pixelSize.width * fit) / 2 * 2
        let height = Int(pixelSize.height * fit) / 2 * 2
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.queueDepth = 6

        try? FileManager.default.removeItem(at: videoURL)
        try FileManager.default.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.checkSettled() }
        timer.resume()
        self.timer = timer
    }

    /// The screen as it is now.
    func snapshot() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: latest.flatMap(image))
            }
        }
    }

    /// Stops recording. The video URL is nil when nothing was recorded.
    func stop() async -> (video: URL?, changes: [Change]) {
        try? await stream?.stopCapture()
        stream = nil
        let (writer, input, changes, wrote) = await withCheckedContinuation { continuation in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                checkSettled(force: true)
                continuation.resume(returning: (self.writer, self.input, self.changes, startedSession))
            }
        }
        guard let writer, wrote else {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: videoURL)
            return (nil, changes)
        }
        input?.markAsFinished()
        await writer.finishWriting()
        return (writer.status == .completed ? videoURL : nil, changes)
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        latest = pixels
        write(sampleBuffer)
        watch(Self.grid(of: pixels), at: CACurrentMediaTime())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}

    private func write(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input else { return }
        if !startedSession {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            startedSession = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func watch(_ grid: [Float], at time: CFTimeInterval) {
        guard let reference else {
            self.reference = grid
            previous = grid
            return
        }
        if let previous, Self.share(changedBetween: previous, and: grid, by: 0.03) > 0.002 {
            lastMovement = time
        }
        previous = grid
        if changeStart == nil, Self.share(changedBetween: reference, and: grid, by: 0.06) >= Self.changeShare {
            changeStart = time
        }
    }

    private func checkSettled(force: Bool = false) {
        guard let start = changeStart, let latest, let grid = previous else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastMovement >= Self.settleSeconds else { return }
        changeStart = nil
        guard let reference, Self.share(changedBetween: reference, and: grid, by: 0.06) >= Self.changeShare else { return }
        self.reference = grid
        guard !force, let image = image(latest) else { return }
        changes.append(Change(time: start, image: image))
        if let onChange { DispatchQueue.main.async { onChange(start) } }
    }

    private func image(_ pixels: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        return ciContext.createCGImage(image, from: image.extent)
    }

    // MARK: Comparing screens

    nonisolated static let gridSize = (columns: 32, rows: 20)

    /// Brightness of each cell in a coarse grid, 0...1, averaged over a few
    /// samples per cell.
    nonisolated static func grid(of pixels: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let (columns, rows) = gridSize
        var grid = [Float](repeating: 0, count: columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var sum: Float = 0
                for sy in 0 ..< 4 {
                    for sx in 0 ..< 4 {
                        let x = min(width - 1, (column * 4 + sx) * width / (columns * 4) + width / (columns * 8))
                        let y = min(height - 1, (row * 4 + sy) * height / (rows * 4) + height / (rows * 8))
                        let pixel = bytes + y * stride + x * 4
                        // BGRA
                        sum += 0.0722 * Float(pixel[0]) + 0.7152 * Float(pixel[1]) + 0.2126 * Float(pixel[2])
                    }
                }
                grid[row * columns + column] = sum / (16 * 255)
            }
        }
        return grid
    }

    nonisolated static func grid(of image: CGImage) -> [Float] {
        let (columns, rows) = gridSize
        var bytes = [UInt8](repeating: 0, count: columns * rows)
        guard let context = CGContext(
            data: &bytes, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return bytes.map { Float($0) / 255 }
    }

    /// The share of cells whose brightness moved by more than `threshold`.
    nonisolated static func share(changedBetween a: [Float], and b: [Float], by threshold: Float) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let changed = zip(a, b).filter { abs($0 - $1) > threshold }.count
        return Float(changed) / Float(a.count)
    }
}
