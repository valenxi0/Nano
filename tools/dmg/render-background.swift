// Draws the DMG window background at 1x and 2x.
//   swift tools/dmg/render-background.swift tools/dmg
// Icon centers must match tools/dmg/settings.py.
import AppKit
import SwiftUI

let size = CGSize(width: 640, height: 420)
let nanoCenter = CGPoint(x: 180, y: 232)
let appsCenter = CGPoint(x: 460, y: 232)
/// Where Finder centers a label under a 112-point icon at y 222.
let labelY: CGFloat = 297

struct Island: View {
    var body: some View {
        Capsule()
            .fill(Color.black)
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .frame(width: 148, height: 34)
            .overlay {
                HStack(spacing: 9) {
                    eye
                    eye
                }
                // Looking toward Applications.
                .offset(x: 12, y: 1)
            }
            .shadow(color: Color(red: 0.45, green: 0.3, blue: 1).opacity(0.55), radius: 18, y: 4)
    }

    private var eye: some View {
        Ellipse().fill(.white).frame(width: 9, height: 12)
    }
}

/// Finder draws icon labels in black even in dark mode, so each label
/// sits on a light tag.
struct LabelTag: View {
    let width: CGFloat
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.92))
            .frame(width: width, height: 21)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

struct Arrow: View {
    var body: some View {
        let start = CGPoint(x: nanoCenter.x + 82, y: nanoCenter.y - 6)
        let end = CGPoint(x: appsCenter.x - 84, y: nanoCenter.y - 6)
        let control = CGPoint(x: (start.x + end.x) / 2, y: nanoCenter.y - 70)
        ZStack {
            Path { path in
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
            }
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.15), .white.opacity(0.75)],
                    startPoint: .leading, endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 9])
            )
            Path { path in
                // Tangent at the end of the curve points from control to end.
                let angle = atan2(end.y - control.y, end.x - control.x)
                let wing: CGFloat = 11
                path.move(to: CGPoint(
                    x: end.x - wing * cos(angle - .pi / 5),
                    y: end.y - wing * sin(angle - .pi / 5)
                ))
                path.addLine(to: end)
                path.addLine(to: CGPoint(
                    x: end.x - wing * cos(angle + .pi / 5),
                    y: end.y - wing * sin(angle + .pi / 5)
                ))
            }
            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct Background: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.035, green: 0.035, blue: 0.055)
            RadialGradient(
                colors: [Color(red: 0.42, green: 0.24, blue: 1).opacity(0.55), .clear],
                center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 330
            )
            RadialGradient(
                colors: [Color(red: 0.1, green: 0.45, blue: 1).opacity(0.28), .clear],
                center: UnitPoint(x: 0.12, y: 1.05), startRadius: 0, endRadius: 300
            )
            RadialGradient(
                colors: [Color(red: 0.75, green: 0.3, blue: 1).opacity(0.18), .clear],
                center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: 260
            )

            Island()
                .position(x: size.width / 2, y: 40)

            VStack(spacing: 6) {
                Text("Drag Nano into Applications")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("It lives under your menu bar.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: size.width)
            .position(x: size.width / 2, y: 96)

            LabelTag(width: 60).position(x: nanoCenter.x, y: labelY)
            LabelTag(width: 102).position(x: appsCenter.x, y: labelY)
            Arrow()

            Text("Free and open source  ·  github.com/valenxi0/Nano")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.32))
                .frame(width: size.width)
                .position(x: size.width / 2, y: size.height - 26)
        }
        .frame(width: size.width, height: size.height)
    }
}

@MainActor
func render(scale: CGFloat, to url: URL) throws {
    let renderer = ImageRenderer(content: Background().environment(\.colorScheme, .dark))
    renderer.scale = scale
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = size
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try MainActor.assumeIsolated {
    try render(scale: 1, to: output.appendingPathComponent("background.png"))
    try render(scale: 2, to: output.appendingPathComponent("background@2x.png"))
}
print("Wrote background.png and background@2x.png to \(output.path)")
