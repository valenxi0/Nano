import AppKit
import QuartzCore
import SwiftUI

/// Nano's motion vocabulary. Everything that moves with the island takes its
/// timing from here, so the shell, its content and the chrome under it move
/// as one object instead of drifting apart on separate curves.
///
/// Rules the values follow: opening is an invitation and closing gets out of
/// the way, so closes are quicker and never bounce; content never appears
/// before its container has room for it; exits are softer than entrances.
enum NanoMotion {
    static let control: Double = 0.11
    static let monthSlide: Double = 0.22

    /// The island dropping open: a touch of life at the end.
    static let open = Animation.spring(response: 0.40, dampingFraction: 0.86)
    /// The island closing: quicker, critically damped, no overshoot.
    static let close = Animation.spring(response: 0.30, dampingFraction: 1.0)
    /// Size changes driven by content: a module swap, a section collapsing.
    static let resize = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// The house curve for anything that is not a spring: content reveals,
    /// swaps, slides. Fast out of the gate, long gentle settle.
    static func smooth(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Incoming content in a swap or reveal.
    static let reveal = smooth(0.25)
    /// Outgoing content: gone before the incoming content arrives.
    static let dismiss = Animation.easeOut(duration: 0.12)
    /// Content waits this long into an open so the shell has room first.
    static let contentDelay: Double = 0.08

    static func islandResize(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : resize
    }

    static func islandSpring(dropping: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return dropping ? open : close
    }

    /// The chrome under the island rides the island's own spring, a beat
    /// behind on the way in so it reads as attached, and with it on the way
    /// out, since a close is never delayed.
    static func chromeSpring(dropping: Bool, reduceMotion: Bool) -> Animation? {
        guard let spring = islandSpring(dropping: dropping, reduceMotion: reduceMotion) else {
            return nil
        }
        return dropping ? spring.delay(0.04) : spring
    }
}

/// Opacity, scale and blur together: what every content swap animates. A
/// crossfade alone reads as a flicker when the content also changes size.
private struct NanoSwapModifier: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let blur: CGFloat
    let anchor: UnitPoint
    let offsetY: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale, anchor: anchor)
            .blur(radius: blur)
            .offset(y: offsetY)
    }
}

extension AnyTransition {
    /// Content that replaces other content in place. The old copy leaves
    /// quickly; the new one settles in after `delay`.
    static func nanoSwap(
        anchor: UnitPoint = .center,
        scale: CGFloat = 0.98,
        delay: Double = 0,
        reduceMotion: Bool = false
    ) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity.animation(.easeOut(duration: 0.15))
        }
        let identity = NanoSwapModifier(opacity: 1, scale: 1, blur: 0, anchor: anchor, offsetY: 0)
        return .asymmetric(
            insertion: .modifier(
                active: NanoSwapModifier(opacity: 0, scale: scale, blur: 3, anchor: anchor, offsetY: 0),
                identity: identity
            )
            .animation(NanoMotion.reveal.delay(delay)),
            removal: .modifier(
                active: NanoSwapModifier(opacity: 0, scale: scale, blur: 2, anchor: anchor, offsetY: 0),
                identity: identity
            )
            .animation(NanoMotion.dismiss)
        )
    }

    /// Something that appears just under the island: it rises into place
    /// and leaves faster than it came.
    static func nanoRise(reduceMotion: Bool = false) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity.animation(.easeOut(duration: 0.15))
        }
        let identity = NanoSwapModifier(opacity: 1, scale: 1, blur: 0, anchor: .top, offsetY: 0)
        return .asymmetric(
            insertion: .modifier(
                active: NanoSwapModifier(opacity: 0, scale: 1, blur: 2, anchor: .top, offsetY: -6),
                identity: identity
            )
            .animation(NanoMotion.reveal),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        )
    }
}

/// Travelling crest used by the compact working-state text.
enum NanoCrestWave {
    static let period = 2 * Double.pi / 3.6
    static let itemOffset = 0.42 / 3.6

    private static let sampleCount = 24
    private static let crest: [Double] = (0...sampleCount).map { step in
        let phase = Double(step) / Double(sampleCount) * 2 * .pi
        return pow(max(sin(phase), 0), 4)
    }

    static let keyTimes: [NSNumber] = (0...sampleCount).map {
        NSNumber(value: Double($0) / Double(sampleCount))
    }

    static let textOpacity: [NSNumber] = crest.map {
        NSNumber(value: 0.5 + 0.5 * $0)
    }
}

/// A restrained left-to-right acknowledgement for active provider marks.
///
/// Each logo rises and brightens for 250 ms, settles over 350 ms, then the
/// group rests before the next pass. Keeping this separate from the text crest
/// avoids the fuzzy halo that made neighboring provider shapes merge.
enum NanoProviderRipple {
    static let duration: CFTimeInterval = 2.04
    static let itemOffset: CFTimeInterval = 0.08
    static let keyTimes: [NSNumber] = [
        0,
        NSNumber(value: 0.25 / duration),
        NSNumber(value: 0.60 / duration),
        1,
    ]
    static let opacity: [NSNumber] = [0.72, 1, 0.72, 0.72]
    static let translationY: [NSNumber] = [0, -1.5, 0, 0]
    static let scale: [NSNumber] = [1, 1.03, 1, 1]
}

/// How much motion the island can afford right now.
///
/// A `TimelineView` re-runs its body every frame, which rebuilds that slice of
/// the SwiftUI graph every frame — by far the largest cost in an app that
/// otherwise sits still. So frame rate is budgeted by how much attention the
/// surface actually has, rather than left at design rate forever.
enum NanoMotionBudget: Sendable {
    /// Expanded or hovered. The user is looking straight at it.
    case full
    /// The collapsed strip. It sits in peripheral vision, where low frame
    /// rates read as stutter rather than as calm, so it runs at up to 30fps.
    case ambient
    /// Nothing can see it: occluded by another window, or the display slept.
    case hidden

    var isPaused: Bool {
        if case .hidden = self { return true }
        return false
    }

    /// Widens a component's design frame interval to fit the budget.
    ///
    /// Cost is per-component because the two animations in the collapsed strip
    /// differ by ~19× per frame: throttling both to protect the expensive one
    /// made the cheap one choppy for no measurable saving.
    func interval(_ base: Double, cost: NanoMotionCost = .heavy) -> Double {
        switch self {
        case .full: return base
        // 12-15fps was cheap but read as stutter at the edge of the eye;
        // 30 reads as smooth there. Still no compact element becomes a
        // display-rate background task.
        case .ambient:
            return max(base, 1.0 / 30)
        // Never 1/60: if something resumes it before the pause takes effect,
        // one slow tick is cheaper than a fast one.
        case .hidden: return 1
        }
    }
}

/// What one frame of a component costs, measured rather than assumed.
enum NanoMotionCost {
    /// Cheap enough to run at design rate even in the collapsed strip.
    case light
    /// Heavy enough that peripheral vision is not worth full frame rate.
    case heavy
}

/// Hosts per-frame content in its own `NSHostingView` so its updates stay
/// local. A `TimelineView` ticking inside the island's root hosting view makes
/// AppKit commit and lay out the entire island every frame; in a nested host
/// with no intrinsic-size reporting, only this square is touched.
///
/// Custom environment does not cross the host boundary: pass what the content
/// reads (the motion budget) explicitly. System values like Reduce Motion are
/// read by the nested host itself.
struct NanoIsolatedHost<Content: View>: NSViewRepresentable {
    let side: CGFloat
    /// Nil keeps the host square.
    var height: CGFloat?
    @ViewBuilder let content: () -> Content

    private var size: CGSize { CGSize(width: side, height: height ?? side) }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        return host
    }

    func updateNSView(_ host: NSHostingView<Content>, context: Context) {
        host.rootView = content()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context) -> CGSize? {
        size
    }
}

private struct NanoMotionBudgetKey: EnvironmentKey {
    static let defaultValue: NanoMotionBudget = .full
}

extension EnvironmentValues {
    var nanoMotionBudget: NanoMotionBudget {
        get { self[NanoMotionBudgetKey.self] }
        set { self[NanoMotionBudgetKey.self] = newValue }
    }
}

struct NanoLoadingRing: View {
    var size: CGFloat = 16
    var label = "Loading"
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRotating = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: max(1.5, size * 0.11))
            Circle()
                .trim(from: 0.08, to: 0.76)
                .stroke(
                    .white.opacity(0.82),
                    style: StrokeStyle(
                        lineWidth: max(1.5, size * 0.11),
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .animation(
                    isRotating
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : nil,
                    value: isRotating
                )
        }
        .frame(width: size, height: size)
        .onAppear { updateRotation() }
        .onChange(of: isActive) { _, _ in updateRotation() }
        .onChange(of: reduceMotion) { _, _ in updateRotation() }
        .onDisappear { isRotating = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func updateRotation() {
        isRotating = isActive && !reduceMotion
    }
}

private struct NanoHoverLiftModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.012 : 1)
            .offset(y: isHovered && !reduceMotion ? -1 : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: NanoMotion.control),
                value: isHovered
            )
            .onHover { isHovered = $0 }
    }
}


struct NanoNotchShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat
    var closesTop = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flare) }
        set { bottomRadius = newValue.first; flare = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let flare = min(flare, rect.width / 2)
        let bottom = min(bottomRadius, (rect.width - flare * 2) / 2, rect.height)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
            control: CGPoint(x: rect.minX + flare, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + flare + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + flare, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - flare - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - flare, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - flare, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - flare, y: rect.minY)
        )
        if closesTop { path.closeSubpath() }

        return path
    }
}

/// The agent "working" orb. One loop of frames is drawn once per colour and
/// played by Core Animation, so the app does no work per frame while an agent
/// runs. The motion repeats exactly every `loop`, so the seam never shows.
struct NanoThinkingOrb: View {
    enum Scale {
        case inline

        var side: CGFloat { 20 }
        var speed: Double { 1.95 }
        var latRings: Int { 4 }
        var lonDensity: Int { 12 }
        var rBase: Double { 1.14 }
        var rDepth: Double { 3.23 }
        var rActive: Double { 0.57 }
    }

    var scale: Scale = .inline
    var isActive = true
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget

    var body: some View {
        NanoThinkingOrbRepresentable(
            scale: scale,
            tint: NSColor(tint),
            isAnimating: isActive && !reduceMotion && !budget.isPaused
        )
        .frame(width: scale.side, height: scale.side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }

    fileprivate static let framesPerSecond = 30.0
    private static let moveCount = 14
    private static let step = 0.42
    private static let hold = 1.2
    /// One full sequence of turns, in orb time.
    fileprivate static let loop = 2 * Double(moveCount) * step + hold
    private static let inkFar = 0.62
    private static let inkSpan = 0.54
    private static let rMin = 0.3
    fileprivate static let restingTime = 0.6

    /// Draws the orb at `time` into a square `pixels` wide.
    fileprivate static func render(scale: Scale, tint: NSColor, time: Double, pixels: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let color = tint.usingColorSpace(.sRGB) ?? .white
        let unit = CGFloat(pixels) / scale.side
        context.scaleBy(x: unit, y: unit)
        context.translateBy(x: 0, y: scale.side)
        context.scaleBy(x: 1, y: -1)

        let side = Double(scale.side)
        let center = side / 2
        let radius = side / 2 * 0.82
        let dotScale = pow(side / 300, 0.6)
        let state = sequence(time: time)

        // Whole turns of spin and tilt per loop, so the last frame meets the first.
        let yaw = time * 2 * .pi / loop
        let pitch = 0.35 + 0.1 * sin(time * 4 * .pi / loop)
        let sinYaw = sin(yaw), cosYaw = cos(yaw)
        let sinPitch = sin(pitch), cosPitch = cos(pitch)

        var dots: [(x: Double, y: Double, z: Double, r: Double, white: Double)] = []
        for ring in 0...scale.latRings {
            let phi = -Double.pi / 2 + Double(ring) / Double(scale.latRings) * .pi
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let steps = max(1, Int((abs(cosPhi) * Double(scale.lonDensity)).rounded()))
            for index in 0..<steps {
                let theta = Double(index) / Double(steps) * 2 * .pi
                let turned = rotate((cosPhi * cos(theta), sinPhi, cosPhi * sin(theta)), state: state)
                let u = turned.0 * cosYaw + turned.2 * sinYaw
                let h = -turned.0 * sinYaw + turned.2 * cosYaw
                let b = turned.1 * cosPitch - h * sinPitch
                let depth = turned.1 * sinPitch + h * cosPitch
                let shade = (depth + 1) / 2
                dots.append((
                    x: center + u * radius,
                    y: center - b * radius,
                    z: depth,
                    r: (scale.rBase + scale.rDepth * shade + (turned.3 ? scale.rActive : 0)) * dotScale,
                    white: inkFar - inkSpan * shade - (turned.3 ? 0.14 : 0)
                ))
            }
        }

        for dot in dots.sorted(by: { $0.z < $1.z }) {
            let r = max(rMin, dot.r)
            let alpha = color.alphaComponent * (1 - min(max(dot.white, 0), 1))
            context.setFillColor(color.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
        }
        return context.makeImage()
    }

    private struct Move {
        let axis: Int
        let lo: Double
        let hi: Double
        let ang: Double
    }

    private static func hash(_ index: Int, _ seed: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + seed * 78.233) * 43758.5453
        return value - floor(value)
    }

    private static let moves: [Move] = (0..<moveCount).map { index in
        let axis = min(2, Int(hash(index, 2.3) * 3))
        let lo = -1 + 0.5 * Double(min(3, Int(hash(index, 5.9) * 4)))
        let direction: Double = hash(index, 7.7) < 0.5 ? 1 : -1
        return Move(axis: axis, lo: lo, hi: lo + 0.5, ang: direction * .pi / 2)
    }

    private static func sequence(time: Double) -> (amount: [Double], active: Int) {
        let elapsed = time.truncatingRemainder(dividingBy: loop)
        var amount = [Double](repeating: 0, count: moveCount)
        var active = -1

        guard elapsed < 2 * Double(moveCount) * step else { return (amount, active) }

        let index = Int(elapsed / step)
        let progress = (elapsed - Double(index) * step) / step
        let eased = 1 - pow(1 - min(1, progress / 0.7), 3)

        if index < moveCount {
            for slot in 0..<index { amount[slot] = 1 }
            amount[index] = eased
            active = index
        } else {
            let slot = 2 * moveCount - 1 - index
            for earlier in 0..<slot { amount[earlier] = 1 }
            amount[slot] = 1 - eased
            active = slot
        }
        return (amount, active)
    }

    private static func rotate(
        _ point: (Double, Double, Double),
        state: (amount: [Double], active: Int)
    ) -> (Double, Double, Double, Bool) {
        var (x, y, z) = point
        var touched = false

        for (index, move) in moves.enumerated() {
            let amount = state.amount[index]
            guard amount > 0 else { continue }

            let coordinate = move.axis == 0 ? x : (move.axis == 1 ? y : z)
            guard coordinate >= move.lo, coordinate < move.hi else { continue }

            if index == state.active { touched = true }

            let angle = move.ang * amount
            let c = cos(angle)
            let s = sin(angle)

            switch move.axis {
            case 0:
                let ny = y * c - z * s
                z = y * s + z * c
                y = ny
            case 1:
                let nx = x * c + z * s
                z = -x * s + z * c
                x = nx
            default:
                let nx = x * c - y * s
                y = x * s + y * c
                x = nx
            }
        }
        return (x, y, z, touched)
    }
}

/// Frames for each colour and pixel size, drawn once and shared by every orb.
@MainActor
private enum NanoThinkingOrbFrames {
    private struct Key: Hashable {
        let tint: [CGFloat]
        let pixels: Int
    }

    private static var loops: [Key: [CGImage]] = [:]
    private static var stills: [Key: CGImage] = [:]

    private static func key(_ tint: NSColor, _ pixels: Int) -> Key {
        let color = tint.usingColorSpace(.sRGB) ?? .white
        return Key(tint: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent], pixels: pixels)
    }

    static func loop(scale: NanoThinkingOrb.Scale, tint: NSColor, pixels: Int) -> [CGImage] {
        let key = key(tint, pixels)
        if let cached = loops[key] { return cached }
        let seconds = NanoThinkingOrb.loop / scale.speed
        let count = Int((seconds * NanoThinkingOrb.framesPerSecond).rounded())
        let frames = (0..<count).compactMap { index in
            NanoThinkingOrb.render(
                scale: scale, tint: tint,
                time: Double(index) / Double(count) * NanoThinkingOrb.loop,
                pixels: pixels
            )
        }
        loops[key] = frames
        return frames
    }

    static func still(scale: NanoThinkingOrb.Scale, tint: NSColor, pixels: Int) -> CGImage? {
        let key = key(tint, pixels)
        if let cached = stills[key] { return cached }
        let image = NanoThinkingOrb.render(scale: scale, tint: tint, time: NanoThinkingOrb.restingTime, pixels: pixels)
        stills[key] = image
        return image
    }
}

private struct NanoThinkingOrbRepresentable: NSViewRepresentable {
    let scale: NanoThinkingOrb.Scale
    let tint: NSColor
    let isAnimating: Bool

    func makeNSView(context: Context) -> NanoThinkingOrbView {
        let view = NanoThinkingOrbView()
        view.configure(scale: scale, tint: tint, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: NanoThinkingOrbView, context: Context) {
        view.configure(scale: scale, tint: tint, isAnimating: isAnimating)
    }

    static func dismantleNSView(_ view: NanoThinkingOrbView, coordinator: Void) {
        view.stopAnimating()
    }
}

private final class NanoThinkingOrbView: NSView {
    private static let animationKey = "orb"
    private let frameLayer = CALayer()
    private var scale = NanoThinkingOrb.Scale.inline
    private var tint = NSColor.white
    private var isAnimating = false
    private var pixels = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        frameLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(frameLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Off-window layers keep their animations registered and still tick.
        if window == nil { stopAnimating() } else { apply() }
    }

    func configure(scale: NanoThinkingOrb.Scale, tint: NSColor, isAnimating: Bool) {
        guard tint != self.tint || isAnimating != self.isAnimating || frameLayer.contents == nil else { return }
        self.scale = scale
        self.tint = tint
        self.isAnimating = isAnimating
        apply()
    }

    func stopAnimating() {
        frameLayer.removeAnimation(forKey: Self.animationKey)
    }

    private func apply() {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        pixels = Int((scale.side * backing).rounded())
        frameLayer.contentsScale = backing
        frameLayer.removeAnimation(forKey: Self.animationKey)
        guard isAnimating, window != nil else {
            frameLayer.contents = NanoThinkingOrbFrames.still(scale: scale, tint: tint, pixels: pixels)
            return
        }
        let frames = NanoThinkingOrbFrames.loop(scale: scale, tint: tint, pixels: pixels)
        frameLayer.contents = frames.first
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = NanoThinkingOrb.loop / scale.speed
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // Every orb on screen turns in step, as one clock would.
        animation.beginTime = CACurrentMediaTime()
            - CACurrentMediaTime().truncatingRemainder(dividingBy: animation.duration)
        frameLayer.add(animation, forKey: Self.animationKey)
    }
}

/// Agent activity chip. Every moving part is a Core Animation layer property,
/// so the animation runs on the window server's render thread and the app's
/// main thread does nothing per frame.
///
/// This replaced a `TimelineView` + `Canvas` that redrew the whole chip each
/// tick and measured as the single most expensive thing in Nano — 134 main
/// thread samples where the orb beside it took 7.
struct NanoActivityChip: View {
    let symbol: String
    let text: String
    var tint: Color = .white
    var rimPalette: [AgentAccentComponents] = []
    var maxWidth: CGFloat = 196
    var revolution: Double = 9.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget

    private static let fontSize: CGFloat = 9.5
    private static let height: CGFloat = 19

    var body: some View {
        let label = truncated

        NanoActivityChipRepresentable(
            symbol: symbol,
            text: label,
            tint: NSColor(tint),
            rimPalette: rimPalette.map {
                NSColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
            },
            revolution: revolution,
            isAnimating: !reduceMotion && !budget.isPaused
        )
        .frame(width: Self.width(of: label), height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    static var advance: CGFloat {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            .maximumAdvancement.width
    }

    static func width(of label: String) -> CGFloat {
        16 + 11 + 5 + advance * CGFloat(label.count)
    }

    private var truncated: String {
        let available = maxWidth - 16 - 5 - 12
        let limit = max(Int(available / max(Self.advance, 1)), 8)

        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "\u{2026}"
    }
}

/// A closed spectrum for the multi-session activity rim. Repeating the first
/// color at the end removes the seam where the conic gradient wraps.
enum NanoActivityChipPalette {
    static let multiSession: [AgentAccentComponents] = [
        .init(red: 0.34, green: 0.59, blue: 1.00),
        .init(red: 0.61, green: 0.42, blue: 1.00),
        .init(red: 0.98, green: 0.40, blue: 0.72),
        .init(red: 1.00, green: 0.45, blue: 0.35),
        .init(red: 1.00, green: 0.74, blue: 0.26),
        .init(red: 0.35, green: 0.83, blue: 0.55),
        .init(red: 0.26, green: 0.78, blue: 0.92),
        .init(red: 0.34, green: 0.59, blue: 1.00),
    ]
}

private struct NanoActivityChipRepresentable: NSViewRepresentable {
    let symbol: String
    let text: String
    let tint: NSColor
    let rimPalette: [NSColor]
    let revolution: Double
    let isAnimating: Bool

    func makeNSView(context: Context) -> NanoActivityChipView {
        let view = NanoActivityChipView()
        view.configure(
            symbol: symbol,
            text: text,
            tint: tint,
            rimPalette: rimPalette,
            revolution: revolution,
            isAnimating: isAnimating
        )
        return view
    }

    func updateNSView(_ nsView: NanoActivityChipView, context: Context) {
        nsView.configure(
            symbol: symbol,
            text: text,
            tint: tint,
            rimPalette: rimPalette,
            revolution: revolution,
            isAnimating: isAnimating
        )
    }

    static func dismantleNSView(_ nsView: NanoActivityChipView, coordinator: Void) {
        nsView.stopAnimating()
    }
}

private final class NanoActivityChipView: NSView {
    private let backgroundLayer = CALayer()
    private let rimContainer = CALayer()
    private let rimLayer = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let symbolLayer = CALayer()
    private var glyphLayers: [CATextLayer] = []

    private var symbol = ""
    private var text = ""
    private var tint = NSColor.white
    private var rimPalette: [NSColor] = []
    private var revolution: Double = 9.5
    private var isAnimating = false
    private var built = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        backgroundLayer.cornerRadius = 7
        backgroundLayer.cornerCurve = .continuous
        layer?.addSublayer(backgroundLayer)

        // The gradient spins inside a container that does not. Masking the
        // rotating layer directly would spin the outline itself rather than
        // sweeping the highlight around a stationary rim.
        rimLayer.type = .conic
        rimLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        rimLayer.endPoint = CGPoint(x: 1, y: 0.5)
        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.lineWidth = 1
        rimMask.strokeColor = NSColor.white.cgColor
        rimContainer.mask = rimMask
        rimContainer.addSublayer(rimLayer)
        layer?.addSublayer(rimContainer)

        symbolLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(symbolLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Off-window layers keep their animations registered and still tick.
        if window == nil { stopAnimating() } else { applyAnimations() }
    }

    func configure(
        symbol: String,
        text: String,
        tint: NSColor,
        rimPalette: [NSColor],
        revolution: Double,
        isAnimating: Bool
    ) {
        let identityChanged = symbol != self.symbol
            || text != self.text
            || tint != self.tint
            || rimPalette != self.rimPalette
        let animationChanged = isAnimating != self.isAnimating || revolution != self.revolution
        guard identityChanged || animationChanged || !built else { return }

        self.symbol = symbol
        self.tint = tint
        self.rimPalette = rimPalette
        self.revolution = revolution
        self.isAnimating = isAnimating

        if identityChanged || !built {
            self.text = text
            rebuild()
        }
        applyAnimations()
    }

    override func layout() {
        super.layout()
        rebuild()
        applyAnimations()
    }

    /// Rebuilds only when the text or size changes — never per frame.
    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        built = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        backgroundLayer.frame = bounds

        rimContainer.frame = bounds
        rimMask.frame = bounds
        rimMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 7,
            cornerHeight: 7,
            transform: nil
        )

        // Oversized so the sweep still covers the corners at every angle.
        let side = max(bounds.width, bounds.height) * 1.5
        rimLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        rimLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        rimLayer.colors = rimColors
        rimLayer.locations = rimLocations

        let symbolSide: CGFloat = 11
        symbolLayer.frame = CGRect(x: 8, y: (bounds.height - symbolSide) / 2, width: symbolSide, height: symbolSide)
        symbolLayer.contents = symbolImage(side: symbolSide)

        rebuildGlyphs(originX: 8 + symbolSide + 5)
    }

    private func rebuildGlyphs(originX: CGFloat) {
        for layer in glyphLayers { layer.removeFromSuperlayer() }
        glyphLayers.removeAll(keepingCapacity: true)

        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let advance = font.maximumAdvancement.width
        let scale = window?.backingScaleFactor ?? 2

        for (index, character) in text.enumerated() {
            let glyph = CATextLayer()
            glyph.string = String(character)
            glyph.font = font
            glyph.fontSize = font.pointSize
            glyph.foregroundColor = NSColor.white.cgColor
            glyph.contentsScale = scale
            glyph.alignmentMode = .center
            glyph.frame = CGRect(
                x: originX + advance * CGFloat(index),
                y: (bounds.height - 12) / 2,
                width: advance,
                height: 12
            )
            glyph.opacity = 0.5
            layer?.addSublayer(glyph)
            glyphLayers.append(glyph)
        }
    }

    /// One animation per layer, installed once. The staggered `beginTime` is
    /// what produces the travelling wave without any per-frame bookkeeping.
    private func applyAnimations() {
        guard built else { return }

        rimLayer.removeAllAnimations()
        for glyph in glyphLayers { glyph.removeAllAnimations() }

        guard isAnimating, window != nil else {
            rimLayer.transform = CATransform3DIdentity
            for glyph in glyphLayers { glyph.opacity = 0.5 }
            return
        }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = revolution
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        rimLayer.add(spin, forKey: "nano.chip.rim")

        // Matches the old crest: sin^4, so mostly dim with a sharp bright pass.
        let start = CACurrentMediaTime()

        for (index, glyph) in glyphLayers.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "opacity")
            wave.values = NanoCrestWave.textOpacity
            wave.keyTimes = NanoCrestWave.keyTimes
            wave.duration = NanoCrestWave.period
            wave.repeatCount = .infinity
            wave.isRemovedOnCompletion = false
            wave.beginTime = start - (NanoCrestWave.itemOffset * Double(index))
                .truncatingRemainder(dividingBy: NanoCrestWave.period)
            glyph.add(wave, forKey: "nano.chip.wave")
        }
    }

    func stopAnimating() {
        rimLayer.removeAllAnimations()
        for glyph in glyphLayers { glyph.removeAllAnimations() }
    }

    private var rimColors: [CGColor] {
        if rimPalette.count > 1 {
            return rimPalette.map { $0.withAlphaComponent(0.94).cgColor }
        }

        let highlight = highlightColor
        return [
            tint.withAlphaComponent(0.22), highlight.withAlphaComponent(0.95),
            tint.withAlphaComponent(0.75), tint.withAlphaComponent(0.16),
            highlight.withAlphaComponent(0.78), tint.withAlphaComponent(0.62),
            tint.withAlphaComponent(0.16), tint.withAlphaComponent(0.22),
        ].map(\.cgColor)
    }

    private var rimLocations: [NSNumber] {
        if rimPalette.count > 1 {
            return rimPalette.indices.map { index in
                NSNumber(value: Double(index) / Double(rimPalette.count - 1))
            }
        }

        return [0, 0.09, 0.19, 0.38, 0.57, 0.68, 0.86, 1].map { NSNumber(value: $0) }
    }

    private var highlightColor: NSColor {
        guard let base = tint.usingColorSpace(.sRGB) else { return tint }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: saturation * 0.42,
            brightness: min(brightness * 1.25 + 0.28, 1),
            alpha: 1
        )
    }

    private func symbolImage(side: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .semibold)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let color = rimPalette.count > 1
            ? NSColor.white.withAlphaComponent(0.92)
            : tint.withAlphaComponent(0.9)
        let tinted = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            color.set()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

struct NanoMarqueeText: View {
    let text: String
    var fontSize: CGFloat = 17
    var weight: Font.Weight = .semibold
    var rounded = true
    var height: CGFloat = 22
    var speed: CGFloat = 35
    var dwell: Double = 1.2
    var autoScrolls = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let overflow = max(measuredWidth - proxy.size.width, 0)

            Text(text)
                .font(.system(size: fontSize, weight: weight, design: rounded ? .rounded : .default))
                .fixedSize()
                .offset(x: offset)
                .frame(width: proxy.size.width, height: height, alignment: .leading)
                .clipped()
                .mask(fadeMask(width: proxy.size.width, overflow: overflow))
                .onHover { isHovering = $0 }
                .task(id: ScrollKey(hovering: isHovering, overflow: overflow)) {
                    await scroll(overflow: overflow)
                }
        }
        .frame(height: height)
        .accessibilityLabel(text)
    }

    private struct ScrollKey: Equatable {
        let hovering: Bool
        let overflow: CGFloat
    }

    private func scroll(overflow: CGFloat) async {
        guard autoScrolls || isHovering, overflow > 0, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
            return
        }

        let duration = Double(overflow / speed)

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { break }
            withAnimation(.easeInOut(duration: duration)) { offset = -overflow }

            try? await Task.sleep(for: .seconds(duration + dwell))
            guard !Task.isCancelled else { break }
            withAnimation(.easeInOut(duration: duration)) { offset = 0 }

            try? await Task.sleep(for: .seconds(duration))
        }
    }

    private func fadeMask(width: CGFloat, overflow: CGFloat) -> some View {
        let fade: CGFloat = 16
        let fraction = width > 0 ? min(fade / width, 0.4) : 0
        let fadesLeading = offset < -1
        let fadesTrailing = overflow > 0 && offset > -(overflow - 1)

        return LinearGradient(
            stops: [
                .init(color: .black.opacity(fadesLeading ? 0 : 1), location: 0),
                .init(color: .black, location: fadesLeading ? fraction : 0),
                .init(color: .black, location: fadesTrailing ? 1 - fraction : 1),
                .init(color: .black.opacity(fadesTrailing ? 0 : 1), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var measuredWidth: CGFloat {
        let base = NSFont.systemFont(ofSize: fontSize, weight: appKitWeight)
        let font = rounded
            ? base.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
            : base
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private var appKitWeight: NSFont.Weight {
        switch weight {
        case .semibold: .semibold
        case .bold: .bold
        case .medium: .medium
        default: .regular
        }
    }
}

/// The now-playing equalizer: bars rising from a shared baseline, each on its
/// own uneven rhythm so it reads as a meter rather than a loader. Paused, the
/// bars drop to dots and dim, which still reads without motion.
///
/// Pass the player's colour at full strength; dimming follows `isActive`.
struct NanoWave: View {
    var barCount = 4
    var barWidth: CGFloat = 3
    var height: CGFloat = 22
    var color: Color = .green
    var isActive = true
    var settleDuration: Double = 0.5
    var riseDuration: Double = 0.28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget
    @State private var changedAt = Date.distantPast
    @State private var isSettling = false

    /// Two incommensurate frequencies per bar, so no two bars and no two
    /// cycles line up.
    private static let rhythms: [(Double, Double)] = [
        (7.1, 11.3), (5.3, 9.7), (8.9, 6.1), (6.4, 12.2), (7.7, 10.4),
    ]

    var body: some View {
        TimelineView(
            .animation(minimumInterval: budget.interval(1 / 30), paused: isFrozen || budget.isPaused)
        ) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let energy = energy(at: context.date)

            HStack(alignment: .bottom, spacing: barWidth * 0.75) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(0.42 + 0.58 * restingLift(energy)))
                        .frame(
                            width: barWidth,
                            height: barHeight(at: index, time: time, energy: energy)
                        )
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .task(id: isActive) {
            changedAt = Date()

            guard !isActive else {
                isSettling = false
                return
            }

            isSettling = true
            try? await Task.sleep(for: .seconds(settleDuration))
            isSettling = false
        }
        .accessibilityHidden(true)
    }

    private var isFrozen: Bool {
        reduceMotion || (!isActive && !isSettling)
    }

    /// Under Reduce Motion a playing wave holds a still, mid-height pose so
    /// playing and paused stay distinct.
    private func restingLift(_ energy: Double) -> Double {
        reduceMotion ? (isActive ? 1 : 0) : energy
    }

    private func energy(at date: Date) -> Double {
        guard !reduceMotion else { return isActive ? 0.75 : 0 }

        let elapsed = date.timeIntervalSince(changedAt)

        if isActive {
            let progress = min(max(elapsed / riseDuration, 0), 1)
            return 1 - pow(1 - progress, 2)
        }

        let progress = min(max(elapsed / settleDuration, 0), 1)
        return pow(1 - progress, 2)
    }

    private func barHeight(at index: Int, time: TimeInterval, energy: Double) -> CGFloat {
        guard energy > 0 else { return barWidth }

        let (fast, slow) = Self.rhythms[index % Self.rhythms.count]
        let t = reduceMotion ? 0.9 : time
        let wave = 0.62 * sin(t * fast + Double(index) * 1.7)
            + 0.38 * sin(t * slow + Double(index) * 0.9)
        let level = 0.18 + 0.82 * (0.5 + 0.5 * wave)
        return barWidth + (height - barWidth) * level * energy
    }
}

struct NanoScrollCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> NanoScrollCatchView {
        let view = NanoScrollCatchView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ nsView: NanoScrollCatchView, context: Context) {
        nsView.onStep = onStep
    }

    static func dismantleNSView(_ nsView: NanoScrollCatchView, coordinator: Void) {
        nsView.stopMonitoring()
    }
}

final class NanoScrollCatchView: NSView {
    var onStep: ((Int) -> Void)?

    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var lastStep = Date.distantPast

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }

        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        accumulated += delta

        guard abs(accumulated) >= 14 else { return true }
        guard Date().timeIntervalSince(lastStep) > 0.25 else {
            accumulated = 0
            return true
        }

        lastStep = Date()
        let step = accumulated > 0 ? -1 : 1
        accumulated = 0
        onStep?(step)
        return true
    }
}

extension View {
    func nanoHoverLift() -> some View {
        modifier(NanoHoverLiftModifier())
    }
}

/// Text whose changed characters flip over as it updates, after TextRoll: the
/// old character tips back from its top edge while the new one swings in from
/// below. Unchanged characters stay still. Reduce Motion swaps them plainly.
struct NanoRollingText: View {
    let text: String
    var size: CGFloat = 50

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                ZStack {
                    Text(String(character))
                        .id(character)
                        .transition(reduceMotion ? .identity : .nanoRoll)
                }
                .frame(width: size * 0.6)
            }
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .monospacedDigit()
        .animation(reduceMotion ? nil : .easeIn(duration: 0.32), value: text)
    }
}

/// A turn about the horizontal axis, seen straight on, is a vertical squash
/// by cos(angle). Drawn in 2D so the layer keeps its place: a real 3D
/// rotation lost its position when the island was redrawn.
private struct NanoRollModifier: ViewModifier {
    let angle: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: max(cos(angle * .pi / 180), 0.001), anchor: anchor)
            .opacity(1 - abs(angle) / 90)
    }
}

extension AnyTransition {
    /// One character of `NanoRollingText` flipping over.
    static var nanoRoll: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: NanoRollModifier(angle: -90, anchor: .bottom),
                identity: NanoRollModifier(angle: 0, anchor: .bottom)
            ),
            removal: .modifier(
                active: NanoRollModifier(angle: 90, anchor: UnitPoint(x: 0.5, y: 0.25)),
                identity: NanoRollModifier(angle: 0, anchor: UnitPoint(x: 0.5, y: 0.25))
            )
        )
    }
}

/// Press feedback for buttons that draw their own look: the label as it is,
/// a small shrink and dim while held, and the plain style's dimming when
/// disabled. Down is quick; the release springs back a little softer.
struct NanoPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (pressed ? 0.82 : 1) : 0.4)
            .animation(
                pressed ? .spring(response: 0.18, dampingFraction: 0.8) : .spring(response: 0.28, dampingFraction: 0.72),
                value: pressed
            )
    }
}

extension ButtonStyle where Self == NanoPressStyle {
    static var nanoPress: NanoPressStyle { NanoPressStyle() }
}

/// Press feedback for a tappable surface that is not a Button, such as a
/// dashboard widget with controls of its own inside.
private struct NanoPressable: ViewModifier {
    let scale: CGFloat
    @GestureState private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .brightness(pressed ? -0.03 : 0)
            .animation(
                pressed ? .spring(response: 0.18, dampingFraction: 0.8) : .spring(response: 0.28, dampingFraction: 0.72),
                value: pressed
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true }
            )
    }
}

extension View {
    func nanoPressable(scale: CGFloat = 0.98) -> some View {
        modifier(NanoPressable(scale: scale))
    }
}

/// A slow breath for a "live" dot: the recording light. The symbol pulse
/// effect only works on SF Symbols, not on shapes.
private struct NanoBreathe: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.4 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

extension View {
    func nanoBreathe(active: Bool = true) -> some View {
        modifier(NanoBreathe(active: active))
    }
}
