import AppKit
import ImageIO
import QuartzCore
import SwiftUI

enum BluetoothDevicePresentation: String, Equatable, Sendable {
    case airPodsPro
    case airPodsMax
    case magicKeyboard
    case magicMouse

    static func resolve(
        name: String,
        category: BluetoothAccessoryCategory
    ) -> Self? {
        let normalized = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if category == .headphones {
            if normalized.range(of: #"\bairpods\s+max\b"#, options: .regularExpression) != nil {
                return .airPodsMax
            }
            if normalized.range(of: #"\bairpods\s+pro(?:\b|(?=\d))"#, options: .regularExpression) != nil {
                return .airPodsPro
            }
        }
        if normalized.contains("magic keyboard") { return .magicKeyboard }
        if normalized.contains("magic mouse") { return .magicMouse }

        switch category {
        case .keyboard where normalized.contains("apple"):
            return .magicKeyboard
        case .mouse where normalized.contains("apple"):
            return .magicMouse
        default:
            return nil
        }
    }
}

// Approved Blender renders preserve the reviewed materials, pair geometry,
// lighting, and shared Y-axis motion without a second real-time 3D renderer.
extension BluetoothDevicePresentation {
    var approvedAnimationName: String? {
        switch self {
        case .airPodsPro: "AirPodsPro"
        case .airPodsMax: "AirPodsMax"
        case .magicKeyboard, .magicMouse: nil
        }
    }

    func approvedFrameURL(_ frame: Int, bundle: Bundle = .main) -> URL? {
        guard let name = approvedAnimationName else { return nil }
        return bundle.resourceURL?
            .appendingPathComponent("DeviceAnimations")
            .appendingPathComponent(name)
            .appendingPathComponent(String(format: "frame_%04d.png", frame))
    }

    func approvedPoster(bundle: Bundle = .main) -> NSImage? {
        guard let url = approvedFrameURL(25, bundle: bundle) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct ApprovedDeviceFrames: @unchecked Sendable {
    // CGImages are immutable. Decode off the main thread, display on it.
    let images: [CGImage]

    static func load(directory: URL) -> Self? {
        var images: [CGImage] = []
        images.reserveCapacity(217)
        for frame in 1...217 {
            guard !Task.isCancelled else { return nil }
            let url = directory.appendingPathComponent(String(format: "frame_%04d.png", frame))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            images.append(image)
        }
        return Self(images: images)
    }
}

@MainActor
struct BluetoothDeviceAnimationView: View {
    let presentation: BluetoothDevicePresentation
    let reduceMotion: Bool
    @State private var frames: ApprovedDeviceFrames?
    @State private var loadingFailed = false

    var body: some View {
        Group {
            if reduceMotion || loadingFailed {
                if let poster = presentation.approvedPoster() {
                    Image(nsImage: poster).resizable().scaledToFit()
                } else {
                    Image(systemName: "headphones").font(.system(size: 28))
                }
            } else if let frames {
                ApprovedDevicePlayer(frames: frames)
            } else {
                Color.clear
            }
        }
        .task(id: "\(presentation.rawValue):\(reduceMotion)") {
            frames = nil
            loadingFailed = false
            guard !reduceMotion,
                  let directory = presentation.approvedFrameURL(1)?.deletingLastPathComponent() else { return }
            let task = Task.detached(priority: .userInitiated) {
                ApprovedDeviceFrames.load(directory: directory)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            frames = result
            loadingFailed = result == nil
        }
    }
}

@MainActor
private struct ApprovedDevicePlayer: NSViewRepresentable {
    let frames: ApprovedDeviceFrames

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 112, height: 64))
        view.wantsLayer = true
        guard let layer = view.layer else { return view }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 2
        layer.contents = frames.images.last

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.images + [frames.images.last!]
        animation.keyTimes = (0..<217).map { NSNumber(value: Double($0) / 240) } + [1]
        animation.calculationMode = .discrete
        animation.duration = 4
        animation.repeatCount = 1
        layer.add(animation, forKey: "approvedDeviceConnection")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Void) {
        view.layer?.removeAllAnimations()
        view.layer?.contents = nil
    }
}
