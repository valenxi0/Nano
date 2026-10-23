import AppKit
import SwiftUI

/// Rest-state shapes and hover motion from [Its Hover](https://www.itshover.com/icons).
enum SettingsHoverIcon: String {
    case slidersHorizontal
    case layoutDashboard
    case filledBell
    case terminal
    case radio
    case shieldCheck
    case infoCircle
    case clock
    case alarmClockPlus
    case camera
    case cloud
    case vinyl
    case stack
    case battery
    case bluetooth
    case volume
    case brightness
    case focus
    case listCheck

    var loopsOnSelect: Bool {
        switch self {
        case .slidersHorizontal, .layoutDashboard: true
        default: false
        }
    }
}

extension NanoModuleID {
    var hoverIcon: SettingsHoverIcon {
        switch self {
        case .calendar: .clock
        case .timer: .alarmClockPlus
        case .camera: .camera
        case .weather: .cloud
        case .music: .vinyl
        case .tray: .stack
        case .agents: .terminal
        case .voiceDictation: .radio
        case .battery: .battery
        case .bluetooth: .bluetooth
        case .volume: .volume
        case .brightness: .brightness
        case .notificationLabs: .filledBell
        case .cue: .listCheck
        case .mixer: .slidersHorizontal
        }
    }
}

struct SettingsHoverIconView: View {
    let icon: SettingsHoverIcon
    var playToken = 0
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playID = 0
    @State private var looping = false
    @State private var loopGeneration = 0

    var body: some View {
        Group {
            switch icon {
            case .slidersHorizontal:
                SlidersHorizontalIcon(playing: looping)
            case .layoutDashboard:
                LayoutDashboardIcon(playing: looping)
            case .filledBell:
                FilledBellIcon(playID: playID)
            case .terminal:
                TerminalIcon(playID: playID)
            case .radio:
                RadioIcon(playID: playID)
            case .shieldCheck:
                ShieldCheckIcon(playID: playID)
            case .infoCircle:
                InfoCircleIcon(playID: playID)
            case .clock:
                ClockIcon(playID: playID)
            case .alarmClockPlus:
                AlarmClockPlusIcon(playID: playID)
            case .camera:
                CameraIcon(playID: playID)
            case .cloud:
                CloudIcon(playID: playID)
            case .vinyl:
                VinylIcon(playID: playID)
            case .stack:
                StackIcon(playID: playID)
            case .battery:
                BatteryIcon(playID: playID)
            case .bluetooth:
                BluetoothIcon(playID: playID)
            case .volume:
                VolumeIcon(playID: playID)
            case .brightness:
                BrightnessIcon(playID: playID)
            case .focus:
                FocusCornersIcon(playID: playID)
            case .listCheck:
                ListCheckIcon(playID: playID)
            }
        }
        .frame(width: 16, height: 16)
        .scaleEffect(size / 16)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: playToken) { _, token in
            guard token > 0 else { return }
            pulse()
        }
    }

    private func pulse() {
        guard !reduceMotion else { return }
        if icon.loopsOnSelect {
            startLoop(hold: icon == .slidersHorizontal ? 2 : 0.5)
        } else {
            playID += 1
        }
    }

    private func startLoop(hold: TimeInterval) {
        looping = true
        loopGeneration += 1
        let generation = loopGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(hold))
            guard generation == loopGeneration else { return }
            looping = false
        }
    }
}

private struct IconBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: 24, height: 24)
            .scaleEffect(16 / 24)
            .frame(width: 16, height: 16)
    }
}

private func strokeLine(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> some View {
    Path { path in
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
    }
    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
}

private struct SlidersHorizontalIcon: View {
    var playing: Bool
    @State private var row1: CGFloat = 0
    @State private var row2: CGFloat = 0
    @State private var row3: CGFloat = 0

    var body: some View {
        IconBox {
            ZStack {
                strokeLine(3, 5, 10 - 4 * row1, 5)
                strokeLine(14 - 4 * row1, 3, 14 - 4 * row1, 7)
                strokeLine(14 - 4 * row1, 5, 21, 5)

                strokeLine(3, 12, 8 + 4 * row2, 12)
                strokeLine(8 + 4 * row2, 10, 8 + 4 * row2, 14)
                strokeLine(12 + 4 * row2, 12, 21, 12)

                strokeLine(3, 19, 12 - 4 * row3, 19)
                strokeLine(16 - 4 * row3, 17, 16 - 4 * row3, 21)
                strokeLine(16 - 4 * row3, 19, 21, 19)
            }
        }
        .onChange(of: playing) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    row1 = 1
                }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true).delay(0.2)) {
                    row2 = 1
                }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true).delay(0.4)) {
                    row3 = 1
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    row1 = 0
                    row2 = 0
                    row3 = 0
                }
            }
        }
    }
}

private struct LayoutDashboardIcon: View {
    var playing: Bool

    var body: some View {
        IconBox {
            ZStack(alignment: .topLeading) {
                tile(7, 9)
                    .offset(x: 3 + (playing ? 10 : 0), y: 3)
                tile(7, 5)
                    .offset(x: 14 + (playing ? -1 : 0), y: 3 + (playing ? 12 : 0))
                tile(7, 9)
                    .offset(x: 14 + (playing ? -10 : 0), y: 12)
                tile(7, 5)
                    .offset(x: 3 + (playing ? 1 : 0), y: 16 + (playing ? -12 : 0))
            }
            .frame(width: 24, height: 24, alignment: .topLeading)
        }
        .animation(playing ? .easeInOut(duration: 0.3) : .easeInOut(duration: 0.2), value: playing)
    }

    private func tile(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: width, height: height)
    }
}

private struct BellMotion: Equatable {
    var bell: CGFloat = 0
    var clapper: CGFloat = 0
}

private struct FilledBellIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: BellMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(nsImage: templateSVG(fill: Self.clapperPath))
                        .resizable()
                        .renderingMode(.template)
                        .rotationEffect(.degrees(motion.clapper), anchor: UnitPoint(x: 0.5, y: 0))
                    Image(nsImage: templateSVG(fill: Self.bellPath))
                        .resizable()
                        .renderingMode(.template)
                        .rotationEffect(.degrees(motion.bell), anchor: UnitPoint(x: 0.5, y: 0.1))
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.bell) {
                CubicKeyframe(-8, duration: 0.10)
                CubicKeyframe(6, duration: 0.12)
                CubicKeyframe(-4, duration: 0.12)
                CubicKeyframe(2, duration: 0.12)
                CubicKeyframe(0, duration: 0.14)
            }
            KeyframeTrack(\.clapper) {
                LinearKeyframe(0, duration: 0.05)
                CubicKeyframe(20, duration: 0.10)
                CubicKeyframe(-18, duration: 0.12)
                CubicKeyframe(12, duration: 0.12)
                CubicKeyframe(-6, duration: 0.12)
                CubicKeyframe(0, duration: 0.09)
            }
        }
    }

    private static let clapperPath = "M14.235 19c.865 0 1.322 1.024 .745 1.668a3.992 3.992 0 0 1 -2.98 1.332a3.992 3.992 0 0 1 -2.98 -1.332c-.552 -.616 -.158 -1.579 .634 -1.661l.11 -.006h4.471z"
    private static let bellPath = "M12 2c1.358 0 2.506 .903 2.875 2.141l.046 .171l.008 .043a8.013 8.013 0 0 1 4.024 6.069l.028 .287l.019 .289v2.931l.021 .136a3 3 0 0 0 1.143 1.847l.167 .117l.162 .099c.86 .487 .56 1.766 -.377 1.864l-.116 .006h-16c-1.028 0 -1.387 -1.364 -.493 -1.87a3 3 0 0 0 1.472 -2.063l.021 -.143l.001 -2.97a8 8 0 0 1 3.821 -6.454l.248 -.146l.01 -.043a3.003 3.003 0 0 1 2.562 -2.29l.182 -.017l.176 -.004z"
}

private struct TerminalMotion: Equatable {
    var chevronX: CGFloat = 0
    var cursorOpacity: CGFloat = 1
}

private struct TerminalIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: TerminalMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 5, y: 7))
                        path.addLine(to: CGPoint(x: 10, y: 12))
                        path.addLine(to: CGPoint(x: 5, y: 17))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .offset(x: motion.chevronX)
                    strokeLine(12, 19, 19, 19)
                        .opacity(motion.cursorOpacity)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.chevronX) {
                CubicKeyframe(2, duration: 0.15)
                CubicKeyframe(0, duration: 0.15)
            }
            KeyframeTrack(\.cursorOpacity) {
                CubicKeyframe(0, duration: 0.16)
                CubicKeyframe(1, duration: 0.16)
                CubicKeyframe(0, duration: 0.16)
                CubicKeyframe(1, duration: 0.16)
                CubicKeyframe(1, duration: 0.16)
            }
        }
    }
}

private struct RadioMotion: Equatable {
    var center: CGFloat = 1
    var inner: CGFloat = 1
    var innerOpacity: CGFloat = 1
    var outer: CGFloat = 1
    var outerOpacity: CGFloat = 1
}

private struct RadioIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: RadioMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    wave(radius: 6, start: 135, end: 225)
                        .opacity(motion.innerOpacity)
                        .scaleEffect(motion.inner)
                    wave(radius: 6, start: -45, end: 45)
                        .opacity(motion.innerOpacity)
                        .scaleEffect(motion.inner)
                    wave(radius: 10, start: 135, end: 225)
                        .opacity(motion.outerOpacity)
                        .scaleEffect(motion.outer)
                    wave(radius: 10, start: -45, end: 45)
                        .opacity(motion.outerOpacity)
                        .scaleEffect(motion.outer)
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .frame(width: 4, height: 4)
                        .scaleEffect(motion.center)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.center) {
                CubicKeyframe(1.3, duration: 0.25)
                CubicKeyframe(1, duration: 0.25)
            }
            KeyframeTrack(\.inner) {
                LinearKeyframe(1, duration: 0.1)
                CubicKeyframe(1.15, duration: 0.3)
                CubicKeyframe(1, duration: 0.3)
            }
            KeyframeTrack(\.innerOpacity) {
                LinearKeyframe(1, duration: 0.1)
                CubicKeyframe(0.6, duration: 0.3)
                CubicKeyframe(1, duration: 0.3)
            }
            KeyframeTrack(\.outer) {
                LinearKeyframe(1, duration: 0.2)
                CubicKeyframe(1.2, duration: 0.35)
                CubicKeyframe(1, duration: 0.35)
            }
            KeyframeTrack(\.outerOpacity) {
                LinearKeyframe(1, duration: 0.2)
                CubicKeyframe(0.4, duration: 0.35)
                CubicKeyframe(1, duration: 0.35)
            }
        }
    }

    private func wave(radius: CGFloat, start: CGFloat, end: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: CGPoint(x: 12, y: 12),
                radius: radius,
                startAngle: .degrees(start),
                endAngle: .degrees(end),
                clockwise: false
            )
        }
        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .frame(width: 24, height: 24)
    }
}

private struct ShieldMotion: Equatable {
    var scale: CGFloat = 1
    var check: CGFloat = 1
}

private struct ShieldCheckIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: ShieldMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(nsImage: templateSVG(stroke: Self.shieldPath))
                        .resizable()
                        .renderingMode(.template)
                        .scaleEffect(motion.scale)
                    Path { path in
                        path.move(to: CGPoint(x: 15, y: 19))
                        path.addLine(to: CGPoint(x: 17, y: 21))
                        path.addLine(to: CGPoint(x: 21, y: 17))
                    }
                    .trim(from: 0, to: motion.check)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.05, duration: 0.175)
                CubicKeyframe(1, duration: 0.175)
            }
            KeyframeTrack(\.check) {
                CubicKeyframe(0, duration: 0.02)
                CubicKeyframe(1, duration: 0.3)
            }
        }
    }

    private static let shieldPath = "M11.46 20.846a12 12 0 0 1 -7.96 -14.846a12 12 0 0 0 8.5 -3a12 12 0 0 0 8.5 3a12 12 0 0 1 -.09 7.06"
}

private struct ListCheckMotion: Equatable {
    var first: CGFloat = 1
    var second: CGFloat = 1
    var third: CGFloat = 1
}

/// Tabler's list-check. The three ticks draw in top to bottom.
private struct ListCheckIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: ListCheckMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(nsImage: templateSVG(strokes: ["M11 6l9 0", "M11 12l9 0", "M11 18l9 0"]))
                        .resizable()
                        .renderingMode(.template)
                    tick(y: 5.5, progress: motion.first)
                    tick(y: 11.5, progress: motion.second)
                    tick(y: 17.5, progress: motion.third)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.first) {
                CubicKeyframe(0, duration: 0.02)
                CubicKeyframe(1, duration: 0.18)
            }
            KeyframeTrack(\.second) {
                CubicKeyframe(0, duration: 0.02)
                LinearKeyframe(0, duration: 0.08)
                CubicKeyframe(1, duration: 0.18)
            }
            KeyframeTrack(\.third) {
                CubicKeyframe(0, duration: 0.02)
                LinearKeyframe(0, duration: 0.16)
                CubicKeyframe(1, duration: 0.18)
            }
        }
    }

    private func tick(y: CGFloat, progress: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 3.5, y: y))
            path.addLine(to: CGPoint(x: 5, y: y + 1.5))
            path.addLine(to: CGPoint(x: 7.5, y: y - 1))
        }
        .trim(from: 0, to: progress)
        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

private struct InfoMotion: Equatable {
    var dot: CGFloat = 1
    var stem: CGFloat = 1
}

private struct InfoCircleIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: InfoMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .padding(3)
                    Circle()
                        .frame(width: 2, height: 2)
                        .position(x: 12, y: 9)
                        .opacity(motion.dot)
                    Path { path in
                        path.move(to: CGPoint(x: 12, y: 12))
                        path.addLine(to: CGPoint(x: 12, y: 16))
                    }
                    .trim(from: 0, to: motion.stem)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.dot) {
                CubicKeyframe(0, duration: 0.02)
                CubicKeyframe(1, duration: 0.28)
            }
            KeyframeTrack(\.stem) {
                CubicKeyframe(0, duration: 0.02)
                CubicKeyframe(1, duration: 0.38)
            }
        }
    }
}

private struct ClockMotion: Equatable {
    var rotation: CGFloat = 0
}

private struct ClockIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: ClockMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(nsImage: templateSVG(stroke: "M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"))
                        .resizable()
                        .renderingMode(.template)
                    Image(nsImage: templateSVG(stroke: "M12 7v5l3 3"))
                        .resizable()
                        .renderingMode(.template)
                        .rotationEffect(.degrees(motion.rotation))
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.rotation) {
                CubicKeyframe(360, duration: 0.7)
                CubicKeyframe(360, duration: 0.02)
            }
        }
    }
}

private struct AlarmClockPlusIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: playID) { shake in
            IconBox {
                Image(
                    nsImage: templateSVG(strokes: [
                        "M12 13m-8 0a8 8 0 1 0 16 0a8 8 0 1 0 -16 0",
                        "M5 3L2 6",
                        "M22 6L19 3",
                        "M6.38 18.7L4 21",
                        "M17.64 18.67L20 21",
                        "M10 13h4",
                        "M12 11v4"
                    ])
                )
                .resizable()
                .renderingMode(.template)
                .offset(x: shake)
            }
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(-1.4, duration: 0.06)
                CubicKeyframe(1.4, duration: 0.08)
                CubicKeyframe(-1.2, duration: 0.08)
                CubicKeyframe(1.2, duration: 0.08)
                CubicKeyframe(0, duration: 0.1)
            }
        }
    }
}

private struct CameraMotion: Equatable {
    var lens: CGFloat = 1
    var bodyScale: CGFloat = 1
}

private struct CameraIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: CameraMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(
                        nsImage: templateSVG(
                            stroke: "M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z"
                        )
                    )
                    .resizable()
                    .renderingMode(.template)
                    .scaleEffect(motion.bodyScale)
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .frame(width: 6, height: 6)
                        .offset(y: 1)
                        .scaleEffect(motion.lens)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.lens) {
                CubicKeyframe(1.2, duration: 0.18)
                CubicKeyframe(1, duration: 0.18)
            }
            KeyframeTrack(\.bodyScale) {
                CubicKeyframe(0.95, duration: 0.18)
                CubicKeyframe(1, duration: 0.18)
            }
        }
    }
}

private struct CloudIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: playID) { scale in
            IconBox {
                Image(nsImage: templateSVG(stroke: "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"))
                    .resizable()
                    .renderingMode(.template)
                    .scaleEffect(scale)
            }
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(1.08, duration: 0.22)
                CubicKeyframe(1, duration: 0.22)
            }
        }
    }
}

private struct VinylMotion: Equatable {
    var rotation: CGFloat = 0
    var center: CGFloat = 1
}

private struct VinylIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: VinylMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(
                        nsImage: templateSVG(strokes: [
                            "M16 3.937a9 9 0 1 0 5 8.063",
                            "M20 4m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0",
                            "M20 4l-3.5 10l-2.5 2"
                        ])
                    )
                    .resizable()
                    .renderingMode(.template)
                    .rotationEffect(.degrees(motion.rotation))
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .frame(width: 2, height: 2)
                        .scaleEffect(motion.center)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.rotation) {
                CubicKeyframe(360, duration: 0.7)
            }
            KeyframeTrack(\.center) {
                CubicKeyframe(1.25, duration: 0.2)
                CubicKeyframe(1, duration: 0.2)
            }
        }
    }
}

private struct StackIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: playID) { lift in
            IconBox {
                ZStack {
                    Image(nsImage: templateSVG(stroke: "M4 14l8 4l8 -4"))
                        .resizable()
                        .renderingMode(.template)
                    Image(nsImage: templateSVG(stroke: "M12 6l-8 4l8 4l8 -4l-8 -4"))
                        .resizable()
                        .renderingMode(.template)
                        .offset(y: lift)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(-2.5, duration: 0.2)
                CubicKeyframe(0, duration: 0.22)
            }
        }
    }
}

private struct BatteryMotion: Equatable {
    var bolt: CGFloat = 1
    var scale: CGFloat = 1
}

private struct BatteryIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: BatteryMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(
                        nsImage: templateSVG(strokes: [
                            "M6 7h11a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-11a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2",
                            "M20 10v4"
                        ])
                    )
                    .resizable()
                    .renderingMode(.template)
                    .scaleEffect(motion.scale)
                    Image(nsImage: templateSVG(stroke: "M13 9l-3 4h4l-3 4"))
                        .resizable()
                        .renderingMode(.template)
                        .opacity(motion.bolt)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.bolt) {
                CubicKeyframe(0, duration: 0.02)
                CubicKeyframe(1, duration: 0.28)
            }
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.06, duration: 0.18)
                CubicKeyframe(1, duration: 0.2)
            }
        }
    }
}

private struct BluetoothMotion: Equatable {
    var scale: CGFloat = 1
    var dots: CGFloat = 1
}

private struct BluetoothIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: BluetoothMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(nsImage: templateSVG(stroke: "M7 8l10 8l-5 4l0 -16l5 4l-10 8"))
                        .resizable()
                        .renderingMode(.template)
                        .scaleEffect(motion.scale)
                    Image(nsImage: templateSVG(strokes: ["M4 12h1", "M19 12h1"]))
                        .resizable()
                        .renderingMode(.template)
                        .scaleEffect(motion.dots)
                        .opacity(motion.dots)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.1, duration: 0.18)
                CubicKeyframe(1, duration: 0.22)
            }
            KeyframeTrack(\.dots) {
                CubicKeyframe(0.5, duration: 0.18)
                CubicKeyframe(1, duration: 0.22)
            }
        }
    }
}

private struct VolumeMotion: Equatable {
    var inner: CGFloat = 1
    var outer: CGFloat = 1
}

private struct VolumeIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: VolumeMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Image(
                        nsImage: templateSVG(
                            stroke: "M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"
                        )
                    )
                    .resizable()
                    .renderingMode(.template)
                    Image(nsImage: templateSVG(stroke: "M16 9a5 5 0 0 1 0 6"))
                        .resizable()
                        .renderingMode(.template)
                        .scaleEffect(motion.inner, anchor: UnitPoint(x: 0.66, y: 0.5))
                        .opacity(0.6 + (0.4 * motion.inner))
                    Image(nsImage: templateSVG(stroke: "M19.364 18.364a9 9 0 0 0 0-12.728"))
                        .resizable()
                        .renderingMode(.template)
                        .scaleEffect(motion.outer, anchor: UnitPoint(x: 0.8, y: 0.5))
                        .opacity(0.45 + (0.55 * motion.outer))
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.inner) {
                CubicKeyframe(1.2, duration: 0.22)
                CubicKeyframe(1, duration: 0.22)
            }
            KeyframeTrack(\.outer) {
                CubicKeyframe(1, duration: 0.08)
                CubicKeyframe(1.28, duration: 0.24)
                CubicKeyframe(1, duration: 0.22)
            }
        }
    }
}

private struct BrightnessMotion: Equatable {
    var center: CGFloat = 1
    var rays: CGFloat = 1
}

private struct BrightnessIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: BrightnessMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .frame(width: 6, height: 6)
                        .scaleEffect(motion.center)
                    Image(
                        nsImage: templateSVG(strokes: [
                            "M12 4v2",
                            "M12 18v2",
                            "M4 12h2",
                            "M18 12h2",
                            "M6.3 6.3l1.4 1.4",
                            "M16.3 16.3l1.4 1.4",
                            "M6.3 17.7l1.4 -1.4",
                            "M16.3 7.7l1.4 -1.4"
                        ])
                    )
                    .resizable()
                    .renderingMode(.template)
                    .opacity(motion.rays)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.center) {
                CubicKeyframe(0.82, duration: 0.2)
                CubicKeyframe(1, duration: 0.22)
            }
            KeyframeTrack(\.rays) {
                CubicKeyframe(0.4, duration: 0.2)
                CubicKeyframe(1, duration: 0.22)
            }
        }
    }
}

private struct FocusCornersMotion: Equatable {
    var center: CGFloat = 1
    var corners: CGFloat = 1
}

private struct FocusCornersIcon: View {
    let playID: Int

    var body: some View {
        KeyframeAnimator(initialValue: FocusCornersMotion(), trigger: playID) { motion in
            IconBox {
                ZStack {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .frame(width: 6, height: 6)
                        .scaleEffect(motion.center)
                    Image(
                        nsImage: templateSVG(strokes: [
                            "M3 7V5a2 2 0 0 1 2-2h2",
                            "M17 3h2a2 2 0 0 1 2 2v2",
                            "M21 17v2a2 2 0 0 1-2 2h-2",
                            "M7 21H5a2 2 0 0 1-2-2v-2"
                        ])
                    )
                    .resizable()
                    .renderingMode(.template)
                    .scaleEffect(motion.corners)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.center) {
                CubicKeyframe(1.35, duration: 0.18)
                CubicKeyframe(1, duration: 0.2)
            }
            KeyframeTrack(\.corners) {
                CubicKeyframe(0.88, duration: 0.18)
                CubicKeyframe(1, duration: 0.2)
            }
        }
    }
}

private func templateSVG(fill path: String) -> NSImage {
    templateImage(
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="black">\
        <path d="\(path)"/></svg>
        """
    )
}

private func templateSVG(stroke path: String) -> NSImage {
    templateSVG(strokes: [path])
}

private func templateSVG(strokes paths: [String]) -> NSImage {
    templateImage(
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" \
        stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
        \(paths.map { "<path d=\"\($0)\"/>" }.joined())</svg>
        """
    )
}

private func templateImage(_ svg: String) -> NSImage {
    let image = NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: 24, height: 24))
    image.isTemplate = true
    return image
}
