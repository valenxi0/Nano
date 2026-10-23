import AppKit
import SwiftUI

/// Settings → HUD → Dashboard. Arrange features on a live, scaled copy of the
/// real dashboard. While a feature is carried, slots that take it are
/// outlined and slots that don't are covered with the reason, before the drop.
/// Clicking a slot opens a picker of everything that fits it; clicking a
/// library card picks the feature up so it can be placed without dragging.
struct DashboardEditor: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    var libraryColumns = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CarriedFeature?
    /// True from the first drag event until the gesture ends, however it ends.
    @GestureState private var isDragging = false
    /// Escape during a drag: ignore the rest of that gesture.
    @State private var dragCancelled = false
    @State private var held: NanoModuleID?
    @State private var hovered: DashboardArea?
    @State private var pickerArea: DashboardArea?
    @State private var previewOrigin: CGPoint = .zero
    @State private var refusal: String?
    @State private var shakes: [DashboardArea: Int] = [:]

    fileprivate struct CarriedFeature: Equatable {
        let module: NanoModuleID
        let source: DashboardArea?
        var location: CGPoint
        var target: DashboardArea?
    }

    private static let space = "nano.dashboardEditor"
    private static let gridInset = CGPoint(x: DashboardLayout.inset, y: DashboardLayout.inset)
    private static var surfaceSize: CGSize {
        CGSize(
            width: DashboardGrid<EmptyView>.naturalSize.width + gridInset.x * 2,
            height: DashboardGrid<EmptyView>.naturalSize.height + gridInset.y * 2
        )
    }

    private var carried: NanoModuleID? { drag?.module ?? held }

    private var libraryModules: [NanoModuleID] {
        let ordered = NanoModuleID.primaryFeatures + NanoModuleID.allCases.filter {
            !NanoModuleID.primaryFeatures.contains($0)
        }
        return ordered.filter {
            settings.isEnabled($0) && !NanoModuleRegistry.slots(for: $0).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            preview
            statusLine
            library
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) { ghost }
        .onExitCommand { cancelCarry() }
        .task(id: isDragging) {
            // A gesture that ends without `onEnded` (the window loses the
            // mouse, a popover takes over) would leave the ghost and the
            // outlines up. This runs after `onEnded` when there is one.
            guard !isDragging else { return }
            drag = nil
            dragCancelled = false
        }
        .animation(quick, value: carried)
        .animation(quick, value: hovered)
    }

    private var quick: Animation? { reduceMotion ? nil : .easeOut(duration: 0.15) }
    private var settle: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82) }

    // MARK: Preview

    private var preview: some View {
        let natural = Self.surfaceSize
        return GeometryReader { proxy in
            let scale = min(1, proxy.size.width / natural.width)
            ZStack(alignment: .topLeading) {
                surface
                    .frame(width: natural.width, height: natural.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                ForEach(DashboardArea.allCases) { area in
                    let rect = slotRect(area, scale: scale)
                    slotHandle(area, scale: scale)
                        .frame(width: rect.width, height: rect.height)
                        .modifier(ShakeEffect(travel: CGFloat(shakes[area] ?? 0)))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            previewOrigin = geometry.frame(in: .named(Self.space)).origin
                            recordSlotProbes(globalOrigin: geometry.frame(in: .global).origin, scale: scale)
                        }
                        .onChange(of: geometry.frame(in: .named(Self.space)).origin) { _, origin in
                            previewOrigin = origin
                            recordSlotProbes(globalOrigin: geometry.frame(in: .global).origin, scale: scale)
                        }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(natural.width / natural.height, contentMode: .fit)
        .frame(maxWidth: natural.width)
        .frame(maxWidth: .infinity)
    }

    /// The island as it draws on screen, flat top against the menu bar.
    private var surface: some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: 30,
            bottomTrailingRadius: 30,
            style: .continuous
        )
        return ZStack(alignment: .topLeading) {
            IslandSurfaceBackground(
                appearance: settings.appearance,
                blackOpacity: settings.blackOpacity,
                glassIntensity: settings.blurIntensity,
                gradientMidpoint: settings.gradientMidpoint,
                surfaceColor: settings.surfaceColor,
                glassTintColor: settings.glassTintColor,
                cornerRadius: 30
            )
            DashboardGrid { area in
                cell(area)
            }
            .frame(
                width: DashboardGrid<EmptyView>.naturalSize.width,
                height: DashboardGrid<EmptyView>.naturalSize.height
            )
            .offset(x: Self.gridInset.x, y: Self.gridInset.y)
        }
        .clipShape(shape)
        .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 0.8) }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func cell(_ area: DashboardArea) -> some View {
        if let module = settings.visibleDashboardFeature(in: area) {
            DashboardWidget(module: module, slot: area.slot, settings: settings, viewModel: viewModel) {}
                .opacity(drag?.source == area ? 0.35 : 1)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                if area.slot != .quick {
                    Text(area.slot.title).font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
            }
        }
    }

    private func slotRect(_ area: DashboardArea, scale: CGFloat) -> CGRect {
        let frame = DashboardGrid<EmptyView>.frames(in: DashboardGrid<EmptyView>.naturalSize)[area] ?? .zero
        return CGRect(
            x: (frame.minX + Self.gridInset.x) * scale,
            y: (frame.minY + Self.gridInset.y) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func area(at location: CGPoint) -> DashboardArea? {
        let local = CGPoint(x: location.x - previewOrigin.x, y: location.y - previewOrigin.y)
        let scale = currentScale
        return DashboardArea.allCases.first { slotRect($0, scale: scale).contains(local) }
    }

    /// Slot frames for window-level tests, from the same maths hit-testing
    /// uses. Slots are placed with `offset`, which layout frames don't see.
    private func recordSlotProbes(globalOrigin: CGPoint, scale: CGFloat) {
        #if DEBUG
        for area in DashboardArea.allCases {
            NanoTestProbe.frames["dashboard.slot.\(area.rawValue)"] =
                slotRect(area, scale: scale).offsetBy(dx: globalOrigin.x, dy: globalOrigin.y)
        }
        #endif
    }

    /// The preview's scale, derived from the last laid-out width.
    @State private var currentScale: CGFloat = 1

    // MARK: Slot handles

    private func slotHandle(_ area: DashboardArea, scale: CGFloat) -> some View {
        let module = settings.dashboardFeature(in: area).flatMap { settings.isEnabled($0) ? $0 : nil }
        let fits = carried.map { area.compatibleModules.contains($0) }
        let isTarget = drag?.target == area
        let shape = RoundedRectangle(cornerRadius: 17 * scale, style: .continuous)

        return ZStack(alignment: .topTrailing) {
            // A full-size base, so outlines and covers appear in place. An
            // empty ZStack sizes to nothing, and new strokes would animate
            // out of its corner.
            Color.clear
            if let carried, fits == false {
                refusalCover(carried, area: area, shape: shape)
            }

            if fits == true {
                shape.strokeBorder(SettingsChrome.accent.opacity(isTarget ? 1 : 0.7), lineWidth: isTarget ? 2.5 : 1.5)
                if isTarget, let carried {
                    Text(dropLabel(carried, onto: module, in: area))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(SettingsChrome.accent, in: Capsule())
                        .fixedSize()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: area.slot == .wide || area.slot == .medium ? .bottom : .top)
                        .offset(y: area.slot == .wide || area.slot == .medium ? -8 : -22)
                }
            } else if pickerArea == area {
                shape.strokeBorder(SettingsChrome.accent, lineWidth: 2)
            } else if hovered == area, carried == nil {
                shape.strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }

            if let module, carried == nil {
                Button {
                    withAnimation(settle) { settings.setDashboardFeature(nil, in: area) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color(white: 0.16), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                        .opacity(hovered == area ? 1 : 0.6)
                        .scaleEffect(hovered == area ? 1.1 : 1)
                        .contentShape(Circle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Remove \(module.dashboardTitle)")
            }
        }
        .contentShape(shape)
        .scaleEffect(isTarget && fits == true && !reduceMotion ? 1.015 : 1)
        .onHover { inside in
            if inside { hovered = area } else if hovered == area { hovered = nil }
        }
        .onTapGesture { tap(area) }
        .gesture(dragGesture(for: module, from: area))
        .popover(isPresented: pickerBinding(area), arrowEdge: .bottom) {
            DashboardSlotPicker(
                area: area,
                settings: settings,
                viewModel: viewModel,
                candidates: libraryModules,
                place: { module in
                    pickerArea = nil
                    place(module, in: area)
                },
                remove: {
                    pickerArea = nil
                    withAnimation(settle) { settings.setDashboardFeature(nil, in: area) }
                }
            )
        }
        .onAppear { currentScale = scale }
        .onChange(of: scale) { _, value in currentScale = value }
        .help(module.map { "\($0.dashboardTitle) · drag to move, click to change" } ?? "Empty \(area.slot.title.lowercased()) slot · click to choose a feature")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(area.slot.title) slot, \(module?.dashboardTitle ?? "empty")")
        .accessibilityIdentifier("dashboard.slot.\(area.rawValue)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap(area) }
        .accessibilityAction(named: "Remove") {
            settings.setDashboardFeature(nil, in: area)
        }
    }

    private func refusalCover(_ module: NanoModuleID, area: DashboardArea, shape: RoundedRectangle) -> some View {
        let compact = area.slot == .quick
        return ZStack {
            shape.fill(Color.black.opacity(0.78))
            shape.strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            VStack(spacing: 3) {
                Image(systemName: "nosign")
                    .font(.system(size: 11, weight: .semibold))
                Text(compact ? "Won't fit" : NanoModuleRegistry.unfitReason(for: module, in: area.slot) ?? "")
                    .font(.system(size: area.slot == .strip ? 9 : 10.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(area.slot == .strip ? 2 : 4)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
        }
        .allowsHitTesting(false)
    }

    private func dropLabel(_ module: NanoModuleID, onto current: NanoModuleID?, in area: DashboardArea) -> String {
        guard let current, current != module else { return current == module ? "Here now" : "Place here" }
        return displacedFeatureStays(current, from: area, carrying: module)
            ? "Swap with \(current.dashboardTitle)"
            : "Replace \(current.dashboardTitle)"
    }

    /// What `moveDashboardFeature` does with the feature already in the
    /// target: it takes the carried feature's old slot when it fits there,
    /// otherwise the first empty slot that takes it, otherwise it comes off.
    private func displacedFeatureStays(
        _ displaced: NanoModuleID,
        from target: DashboardArea,
        carrying module: NanoModuleID
    ) -> Bool {
        let source = drag?.source ?? DashboardArea.allCases.first { settings.dashboardFeature(in: $0) == module }
        if let source, source != target, source.compatibleModules.contains(displaced) { return true }
        return DashboardArea.allCases.contains {
            $0 != target && settings.dashboardFeature(in: $0) == nil && $0.compatibleModules.contains(displaced)
        }
    }

    private func pickerBinding(_ area: DashboardArea) -> Binding<Bool> {
        Binding(
            get: { pickerArea == area },
            set: { shown in
                if !shown, pickerArea == area { pickerArea = nil }
            }
        )
    }

    private func tap(_ area: DashboardArea) {
        if let held {
            place(held, in: area)
        } else {
            pickerArea = area
        }
    }

    // MARK: Dragging

    /// A nil module (an empty slot) makes the gesture inert.
    private func dragGesture(for module: NanoModuleID?, from source: DashboardArea?) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard let module, !dragCancelled else { return }
                if drag == nil {
                    held = nil
                    pickerArea = nil
                    refusal = nil
                    drag = CarriedFeature(module: module, source: source, location: value.location, target: nil)
                }
                drag?.location = value.location
                drag?.target = area(at: value.location)
            }
            .onEnded { value in
                guard !dragCancelled else {
                    dragCancelled = false
                    drag = nil
                    return
                }
                guard let carried = drag else { return }
                drag = nil
                // Dropped outside every slot: it goes back where it was. The
                // slot's × is how a feature comes off.
                guard let target = area(at: value.location) else { return }
                place(carried.module, from: carried.source, in: target)
            }
    }

    private func place(_ module: NanoModuleID, from source: DashboardArea? = nil, in area: DashboardArea) {
        guard area.compatibleModules.contains(module) else {
            refuse(module, in: area)
            return
        }
        let origin = source ?? DashboardArea.allCases.first { settings.dashboardFeature(in: $0) == module }
        withAnimation(settle) {
            _ = settings.moveDashboardFeature(module, from: origin, to: area)
        }
        held = nil
        refusal = nil
    }

    private func refuse(_ module: NanoModuleID, in area: DashboardArea) {
        refusal = NanoModuleRegistry.unfitReason(for: module, in: area.slot)
            .map { "\(module.dashboardTitle) can't go in a \(area.slot.title) slot. \($0)" }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        withAnimation(reduceMotion ? nil : .linear(duration: 0.36)) {
            shakes[area, default: 0] += 1
        }
    }

    private func cancelCarry() {
        // Without this the next drag event would pick the feature up again
        // and the release would still drop it.
        if isDragging { dragCancelled = true }
        drag = nil
        held = nil
    }

    @ViewBuilder
    private var ghost: some View {
        if let drag {
            let removing = drag.source != nil && drag.target == nil
            HStack(spacing: 7) {
                Image(systemName: removing ? "minus" : drag.module.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(removing ? Color.red.opacity(0.8) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(drag.module.dashboardTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(removing ? "Release to remove" : slotLetters(drag.module))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.leading, 7)
            .padding(.trailing, 11)
            .frame(height: 36)
            .background(Color(white: 0.14).opacity(0.96), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            .rotationEffect(.degrees(reduceMotion ? 0 : -2))
            .fixedSize()
            .position(x: drag.location.x + 30, y: drag.location.y - 14)
            .allowsHitTesting(false)
        }
    }

    private func slotLetters(_ module: NanoModuleID) -> String {
        let slots = NanoModuleRegistry.slots(for: module)
        return DashboardSlot.allCases.filter(slots.contains).map(\.shortTitle).joined(separator: " ")
    }

    // MARK: Status line

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 7) {
            if let refusal {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(refusal)
            } else if let held {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(SettingsChrome.accent)
                Text("Click a highlighted slot to place \(held.dashboardTitle).")
                Button("Cancel") { self.held = nil }
                    .buttonStyle(.link)
            } else {
                Text("Features only appear in the slot sizes they're designed for. To remove one, click its ×.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 16)
        .task(id: refusal) {
            guard refusal != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            refusal = nil
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Features")
                    .font(.headline)
                Spacer()
                HStack(spacing: 10) {
                    ForEach(DashboardSlot.allCases) { slot in
                        Text("\(slot.shortTitle) \(slot.title)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: libraryColumns),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(libraryModules) { module in
                    libraryCard(module)
                }
            }
            Text("Only features that are turned on appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func libraryCard(_ module: NanoModuleID) -> some View {
        let placedArea = DashboardArea.allCases.first { settings.visibleDashboardFeature(in: $0) == module }
        let slots = NanoModuleRegistry.slots(for: module)
        let isHeld = held == module
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: module.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(module.dashboardTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    // Setup embeds this grid in a narrower card.
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                if placedArea != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SettingsChrome.accent)
                        .help("On the dashboard")
                }
            }
            HStack(spacing: 3) {
                ForEach(DashboardSlot.allCases) { slot in
                    let fits = slots.contains(slot)
                    Text(slot.shortTitle)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .strikethrough(!fits)
                        .foregroundStyle(fits ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 16)
                        .background(Color.primary.opacity(fits ? 0.1 : 0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .help(fits ? "Fits \(slot.title)" : NanoModuleRegistry.unfitReason(for: module, in: slot) ?? "")
                }
            }
        }
        .padding(10)
        .background(isHeld ? SettingsChrome.accent.opacity(0.14) : Color.primary.opacity(0.045), in: shape)
        .overlay {
            shape.strokeBorder(isHeld ? SettingsChrome.accent : Color.primary.opacity(0.08), lineWidth: isHeld ? 1.2 : 0.5)
        }
        .opacity(drag?.module == module ? 0.5 : 1)
        .contentShape(shape)
        .onTapGesture {
            pickerArea = nil
            refusal = nil
            held = isHeld ? nil : module
        }
        .gesture(dragGesture(for: module, from: nil))
        .help("Drag \(module.dashboardTitle) onto the dashboard, or click to pick it up")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(module.dashboardTitle)\(placedArea == nil ? "" : ", on dashboard")")
        .accessibilityIdentifier("dashboard.library.\(module.rawValue)")
        .testProbe("dashboard.library.\(module.rawValue)")
        .accessibilityHint("Fits \(DashboardSlot.allCases.filter(slots.contains).map(\.title).joined(separator: ", "))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { held = isHeld ? nil : module }
    }
}

/// Click-a-slot picker: every enabled feature that fits, drawn at the slot's
/// real size, then the ones that don't with their reason.
private struct DashboardSlotPicker: View {
    let area: DashboardArea
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    let candidates: [NanoModuleID]
    let place: (NanoModuleID) -> Void
    let remove: () -> Void

    private let width: CGFloat = 300

    private var current: NanoModuleID? { settings.visibleDashboardFeature(in: area) }
    private var fitting: [NanoModuleID] { candidates.filter(area.compatibleModules.contains) }
    private var unfit: [NanoModuleID] { candidates.filter { !area.compatibleModules.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(area.slot.title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            if let current {
                let options = DashboardWidgetOptions.featureOptions(for: current, settings: settings, viewModel: viewModel)
                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(current.dashboardTitle) options")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        DashboardWidgetOptionsView(sections: [options.filter {
                            if case .header = $0.kind { return false } else { return true }
                        }])
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fitting) { module in
                        option(module)
                    }
                    if !unfit.isEmpty {
                        Text("Won't fit here")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(unfit) { module in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: module.symbol)
                                    .frame(width: 16)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(module.dashboardTitle).font(.system(size: 11.5, weight: .semibold))
                                    Text(NanoModuleRegistry.unfitReason(for: module, in: area.slot) ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            if current != nil {
                Divider()
                Button("Remove from Dashboard", role: .destructive, action: remove)
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: width)
    }

    private var caption: String {
        switch area.slot {
        case .wide: "The main stage"
        case .medium: "The second focus"
        case .strip: "One line of status"
        case .quick: "A single tap target"
        }
    }

    private func option(_ module: NanoModuleID) -> some View {
        let natural = DashboardGrid<EmptyView>.frames(in: DashboardGrid<EmptyView>.naturalSize)[area]?.size ?? .zero
        let scale = min(1, (width - 28 - 16) / max(natural.width, 1))
        let isCurrent = current == module
        let placedArea = DashboardArea.allCases.first { settings.visibleDashboardFeature(in: $0) == module }

        return Button { place(module) } label: {
            VStack(alignment: .leading, spacing: 6) {
                DashboardWidget(module: module, slot: area.slot, settings: settings, viewModel: viewModel) {}
                    .frame(width: natural.width, height: natural.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
                    .padding(4)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                    .environment(\.colorScheme, .dark)
                HStack {
                    Text(module.dashboardTitle).font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text(isCurrent ? "Current" : placedArea.map { "Moves from \($0.slot.title)" } ?? "Add")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(
                isCurrent ? SettingsChrome.accent.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isCurrent ? SettingsChrome.accent : Color.primary.opacity(0.08), lineWidth: isCurrent ? 1.2 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }
}

/// Horizontal shake for a refused drop. Each increment of `travel` plays one
/// full shake.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size _: CGSize) -> ProjectionTransform {
        let phase = travel - travel.rounded(.down)
        let offset = sin(phase * .pi * 6) * 5 * (1 - phase)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
