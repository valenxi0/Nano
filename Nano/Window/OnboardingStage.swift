import AppKit
import Combine
import MetalKit
import SwiftUI

/// Borderless windows refuse key status by default; setup has text fields
/// and a default button.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Puts first-run setup on screen: the dimmed desktop behind the island, and
/// the window that grows out of the notch and hangs under it.
@MainActor
final class OnboardingStage {
    let flow: OnboardingFlow
    private let window: OnboardingWindow
    private let dim: NSWindow
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    /// The window is wider than the card so its shadow has room, and as tall
    /// as the screen so the card can slide under an opening island without the
    /// window itself moving.
    private static let sideMargin: CGFloat = 80

    init(settings: NanoSettings, viewModel: IslandViewModel, isReplay: Bool, onClose: @escaping () -> Void) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        var close: () -> Void = {}
        let flow = OnboardingFlow(settings: settings, viewModel: viewModel, isReplay: isReplay) { close() }
        flow.screenHeight = screen.frame.height
        flow.menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        flow.dockHeight = screen.visibleFrame.minY - screen.frame.minY
        self.flow = flow

        let width = OnboardingFlow.windowWidth + Self.sideMargin * 2
        window = OnboardingWindow(
            contentRect: NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.minY,
                width: width,
                height: screen.frame.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.title = "Set Up Nano"
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentView = NSHostingView(rootView: OnboardingExperienceView(flow: flow))

        dim = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        dim.isReleasedWhenClosed = false
        dim.isOpaque = false
        dim.backgroundColor = .clear
        dim.hasShadow = false
        dim.ignoresMouseEvents = true
        dim.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        dim.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        dim.contentView = NSHostingView(rootView: OnboardingDimView(flow: flow))

        close = { [weak self] in
            self?.tearDown()
            onClose()
        }

        flow.$step
            .sink { [weak self] step in self?.stepChanged(step) }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak flow] event in
            guard let flow else { return event }
            switch (flow.step, event.keyCode) {
            case (.arrival, 36): flow.openWindow()
            case (.arrival, 53), (.resume, 53), (.welcome, 53), (.pick, 53), (.room, 53): flow.setUpLater()
            case (.pick, 123): flow.stepShowcase(by: -1)
            case (.pick, 124): flow.stepShowcase(by: 1)
            default: return event
            }
            return nil
        }
    }

    func begin() {
        dim.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        // Activation can be refused when another app is frontmost; the window
        // still has to be seen.
        window.orderFrontRegardless()
        window.makeKey()
        flow.start()
    }

    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        stepChanged(flow.step)
    }

    private func stepChanged(_ step: OnboardingFlow.Step) {
        switch step {
        case .resume, .welcome, .pick, .room, .summary:
            // Behind the card, and behind anything macOS or the user brings
            // forward: permission prompts and System Settings stay reachable.
            // It takes clicks, so a click beside the card cannot bury setup
            // under whatever app is behind it.
            dim.level = .normal
            dim.ignoresMouseEvents = false
            // As a child it stays under the card. On its own, a click on the
            // backdrop would bring the backdrop in front of the card.
            if dim.parent == nil { window.addChildWindow(dim, ordered: .below) }
        case .arrival, .finale:
            // Over everything except the island, which is what is being
            // pointed at.
            if dim.parent != nil { window.removeChildWindow(dim) }
            dim.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            dim.ignoresMouseEvents = true
            dim.orderFrontRegardless()
        }
    }

    func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cancellables.removeAll()
        if dim.parent != nil { window.removeChildWindow(dim) }
        flow.tearDown()
        dim.orderOut(nil)
        window.orderOut(nil)
    }
}

/// The desktop behind the island during the opening and the ending, with the
/// one line that says what to do.
private struct OnboardingDimView: View {
    @ObservedObject var flow: OnboardingFlow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(flow.dimOpacity)
                .animation(.easeInOut(duration: 1.6), value: flow.dimOpacity)
            OnboardingAurora(strength: flow.auroraStrength)
            if flow.showsArrivalPrompt {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .modifier(OnboardingPulse(active: !reduceMotion))
                    Text("Hover me to start")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.3)
                    Text("A short setup. Pick what you want, skip the rest.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.62))
                    HStack(spacing: 22) {
                        keyHint("Return", "Start")
                        keyHint("Esc", "Set up later")
                    }
                    .padding(.top, 12)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 12)
                .padding(.top, max(150, flow.viewModel.preferredSize.height + 70))
                .transition(.opacity)
                VStack {
                    Spacer()
                    Text("Set up later keeps a checklist in Settings, with Replay setup.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.bottom, 28 + flow.dockHeight)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.5), value: flow.showsArrivalPrompt)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Text(key)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.15)))
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
        }
    }
}

/// Light that hangs from the top of the screen, brightest under the island.
/// Under Reduce Motion it holds still.
private struct OnboardingAurora: View {
    let strength: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AuroraLayer(animated: !reduceMotion)
            .opacity(strength)
            // It comes up slowly; arriving all at once is a lot of light.
            .animation(.easeInOut(duration: OnboardingFlow.auroraFade), value: strength)
            .allowsHitTesting(false)
    }
}

private struct AuroraLayer: NSViewRepresentable {
    let animated: Bool

    func makeCoordinator() -> AuroraRenderer { AuroraRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        (view.layer as? CAMetalLayer)?.isOpaque = false
        view.preferredFramesPerSecond = 30
        view.isPaused = !animated
        view.enableSetNeedsDisplay = !animated
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.isPaused = !animated
        view.enableSetNeedsDisplay = !animated
    }
}

/// The shader is compiled from source at launch, so the build needs no Metal
/// toolchain.
private final class AuroraRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var strength: Float
        var left: SIMD4<Float>
        var middle: SIMD4<Float>
        var right: SIMD4<Float>
    }

    let device = MTLCreateSystemDefaultDevice()
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private let start = Date()

    override init() {
        super.init()
        guard let device, let library = try? device.makeLibrary(source: Self.source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "auroraVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "auroraFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        queue = device.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(
            size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            // Starts partway in, so a still frame under Reduce Motion has shape.
            time: Float(Date().timeIntervalSince(start)) + 12,
            strength: 1,
            left: SIMD4(0.23, 0.16, 1.0, 1),
            middle: SIMD4(0.55, 0.30, 1.0, 1),
            right: SIMD4(0.16, 0.50, 1.0, 1)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static let source = """
#include <metal_stdlib>
using namespace metal;

// Simplex noise (Ian McEwan, Ashima Arts), as used by most aurora shaders.
static float3 mod289(float3 x) { return x - floor(x / 289.0) * 289.0; }
static float2 mod289(float2 x) { return x - floor(x / 289.0) * 289.0; }
static float3 permute(float3 x) { return mod289((x * 34.0 + 1.0) * x); }

static float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

struct AuroraUniforms {
    float2 size;
    float time;
    float strength;
    float4 left;
    float4 middle;
    float4 right;
};

struct AuroraVertex {
    float4 position [[position]];
};

vertex AuroraVertex auroraVertex(uint id [[vertex_id]]) {
    // One triangle that covers the screen.
    float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    AuroraVertex out;
    out.position = float4(corners[id], 0.0, 1.0);
    return out;
}

// A curtain of light that hangs from the top of the screen and reaches
// furthest down under the island, so the island reads as its source.
fragment float4 auroraFragment(AuroraVertex in [[stage_in]], constant AuroraUniforms &u [[buffer(0)]]) {
    float2 uv = in.position.xy / u.size;
    uv.y = 1.0 - uv.y;

    float3 ramp = uv.x < 0.5
        ? mix(u.left.rgb, u.middle.rgb, uv.x * 2.0)
        : mix(u.middle.rgb, u.right.rgb, (uv.x - 0.5) * 2.0);

    float height = exp(snoise(float2(uv.x * 2.0 + u.time * 0.1, u.time * 0.25)) * 0.5);
    float centre = exp(-pow((uv.x - 0.5) / 0.3, 2.0));
    height = uv.y * 2.0 - height + 0.2 + centre * 0.4 - 0.3;

    float intensity = 0.6 * height;
    float alpha = smoothstep(-0.05, 0.45, intensity) * u.strength;
    float3 lit = clamp(intensity * ramp * 1.6, 0.0, 1.0);
    return float4(lit * alpha, alpha);
}
"""
}
