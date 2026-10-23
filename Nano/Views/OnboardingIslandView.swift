import AppKit
import SwiftUI

/// What the closed island shows while first-run setup is on screen.
enum OnboardingIslandContent: Hashable, Sendable {
    case greeting(title: String, detail: String?)
    /// Just the eyes, watching, while the window is up.
    case watching
    case done

    /// Cards have their own size. Demos and picks return nil and take the
    /// island's ordinary closed size, because they are laid out like it.
    func cardSize(notchClearance: CGFloat) -> CGSize? {
        let content: CGSize
        switch self {
        case let .greeting(_, detail): content = CGSize(width: 400, height: detail == nil ? 55 : 66)
        case .done: content = CGSize(width: 400, height: 63)
        case .watching: return nil
        }
        return CGSize(width: content.width, height: content.height + max(notchClearance, 10))
    }

    var isCard: Bool { cardSize(notchClearance: 0) != nil }
}

struct OnboardingIslandView: View {
    let content: OnboardingIslandContent
    let notchClearance: CGFloat
    /// The camera housing. Nothing is drawn across it.
    let notchWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch content {
            case let .greeting(text, detail):
                card {
                    HStack(spacing: 14) {
                        OnboardingEyes(size: CGSize(width: 11, height: 14), spacing: 9)
                            .frame(width: 38, height: 38)
                            .background(Color.white.opacity(0.08), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text)
                                .font(.system(size: 18, weight: .semibold))
                                .tracking(-0.2)
                            if let detail {
                                Text(detail)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.62))
                            }
                        }
                    }
                }
            case .done:
                card {
                    VStack(spacing: 2) {
                        HStack(spacing: 10) {
                            OnboardingEyes(size: CGSize(width: 8, height: 10), spacing: 6)
                            Text("You're set.")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        Text("Hover me anytime.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
            case .watching:
                // Just the eyes. In the middle where the screen has no notch;
                // beside it where the middle is the camera housing.
                if notchWidth > 0 {
                    sides { OnboardingEyes(size: CGSize(width: 7, height: 9), spacing: 5) } trailing: {}
                } else {
                    OnboardingEyes(size: CGSize(width: 7, height: 9), spacing: 5)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.78), value: content)
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.top, max(notchClearance, 10) - 5)
    }

    /// The closed island's own layout: content at each end, the middle empty.
    private func sides<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) { leading() }
            Spacer(minLength: notchWidth)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 14)
    }
}

/// Two eyes that blink now and then and look at the pointer, so the island
/// reads as someone paying attention.
private struct OnboardingEyes: View {
    let size: CGSize
    let spacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget
    @State private var closed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: budget.interval(1 / 30, cost: .light), paused: reduceMotion || budget.isPaused)) { _ in
            let look = reduceMotion ? .zero : Self.gaze(reach: size)
            HStack(spacing: spacing) {
                ForEach(0..<2, id: \.self) { _ in
                    Ellipse()
                        .fill(.white)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(y: closed ? 0.1 : 1)
                }
            }
            .offset(look)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: look)
        }
        .padding(.horizontal, size.width * 0.5)
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(600))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2950))
                withAnimation(.easeInOut(duration: 0.12)) { closed = true }
                try? await Task.sleep(for: .milliseconds(130))
                withAnimation(.easeInOut(duration: 0.12)) { closed = false }
            }
        }
        .accessibilityHidden(true)
    }

    /// How far the eyes lean toward the pointer. The island sits at the top
    /// centre of its screen, so that is where they look from.
    private static func gaze(reach: CGSize) -> CGSize {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else {
            return .zero
        }
        let dx = pointer.x - screen.frame.midX
        let dy = (screen.frame.maxY - 22) - pointer.y
        let distance = max(hypot(dx, dy), 1)
        let pull = min(distance / 260, 1)
        return CGSize(
            width: dx / distance * pull * reach.width * 0.5,
            height: dy / distance * pull * reach.height * 0.3
        )
    }
}

/// A slow breath for cues that ask for attention.
struct OnboardingPulse: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.55 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
