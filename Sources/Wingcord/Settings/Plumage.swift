import SwiftUI
import WingcordCore

// MARK: - Plumage
//
// Where a reader builds their own theme. Named for what a bird wears rather than
// for what the control does, because "theme editor" describes the file format
// and not the thing on screen.
//
// THE FIELD IS THE PRODUCT, and that is the whole idea. Every colour picker
// shows you a wheel of saturated hues and then asks you to imagine what your app
// will look like made out of one of them — which is a guess, because a UI ground
// is a *near-black with a cast* and nothing on a hue wheel is that. Plumage's
// field is a continuous sheet of candidate **reading surfaces**: hue across,
// depth down. What a bead is standing on is what the window behind this one
// becomes.
//
// BEADS ON A SHEET. A theme is two to five colours — the darker one behind
// the toolbar, the lit one behind the composer, and up to three the light
// passes through between them — so the instrument has one bead per colour,
// each showing the ground it selects. Drag any; the window behind is the
// preview. (A thread through the beads drew the gradient once, and Alex had it
// taken out, 2026-10-07: "remove the lines that links them".)
//
// So there is no wheel, no eyedropper and no hex box.
//
// THE CONTROLS:
//
//   - **The field.** Every stop a hue and a depth, tracked 1:1 from where the
//     bead was grabbed, and **held at every edge** with the resistance §3
//     asks for. Hue used to wrap, because hue is circular — which made a bead
//     dragged past the right edge leap to the left one (Alex, 2026-10-07: "it
//     restarts from the other side"). The sheet's two ends are both red, so
//     stopping at either loses no colour.
//   - **The light track.** How bright the ground is, drawn as the actual ramp
//     it selects from.
//   - **The dial.** Which way the colours run across the window.
//   - **Minus and plus.** A colour fewer or more between the two ends.
//   - **The accent row.** Five relationships to the lit stop, each drawn in the
//     colour it would produce. No sixth picker — an accent that can be any
//     colour at all is how a theme ends up with a ground and a highlight that
//     have never met.
//   - **Shuffle.** A blend that is *good*, not a blend that is random — see
//     `PlumageShuffle`.

struct PlumageCard: View {
    @Environment(AppModel.self) private var model
    @State private var theme = ThemeStore.shared
    /// The blend as it was when Share was pressed, on its way to the sheet.
    @State private var shareRequest: ThemeShareRequest?
    @Environment(\.motion) private var motion
    /// True for as long as a pointer is on one of the continuous controls.
    /// Suppresses the settle animation so a bead cannot lag the pointer.
    @State private var isTracking = false
    @State private var shuffles = 0
    /// The bead the pointer last grabbed and the arrow keys move. **Held here
    /// rather than in the field**, because the minus button removes *this*
    /// colour — the one the reader is looking at — rather than whichever
    /// happens to be last.
    @State private var active: PlumageStop = .foot

    /// The blend as the window shows it — at the reader's vividness — so every
    /// bead and the track agree with what is behind this window.
    /// Edits still go to the stored blend, which carries no vividness.
    private var seed: ThemeSeed { theme.customSeed.at(vividness: theme.vividness) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeaderRow(
                title: "Plumage",
                help: "Two to five colours, from the lit foot of the window (the big "
                    + "bead) to the dark top. Drag any \u{2014} hue across, depth down \u{2014} "
                    + "and watch the window behind."
            )

            PlumageField(
                seed: seed,
                isTracking: isTracking,
                active: $active,
                edit: edit,
                trackingChanged: setTracking
            )
            .padding(.horizontal, SettingsMetrics.cardContentInset)

            HStack(spacing: Spacing.snug) {
                PlumageLightTrack(
                    seed: seed,
                    isTracking: isTracking,
                    edit: edit,
                    trackingChanged: setTracking
                )
                PlumageAngleDial(seed: seed, edit: edit, trackingChanged: setTracking)
                // One container, so the three read as one cluster of glass and
                // blend where they sit close — §4.
                GlassEffectContainer(spacing: Spacing.base) {
                    HStack(spacing: Spacing.base) {
                        PlumageRoundButton(
                            systemName: "minus",
                            label: "Remove a colour",
                            help: "Takes out the selected colour between the ends, "
                                + "or the last one if an end is selected."
                        ) { removeColour() }
                        .disabled(seed.middle.isEmpty)
                        PlumageRoundButton(
                            systemName: "plus",
                            label: "Add a colour",
                            help: "Adds a colour in the widest gap, without changing the blend."
                        ) { addColour() }
                        .disabled(seed.middle.count >= ThemeSeed.maximumMiddle)
                        PlumageRoundButton(
                            systemName: "shuffle",
                            label: "Shuffle",
                            help: "A blend chosen from the combinations that work.",
                            turns: shuffles
                        ) { shuffle() }
                        PlumageRoundButton(
                            systemName: "square.and.arrow.up",
                            label: "Share",
                            help: "Sends this blend to conversations as Discord\u{2019}s theme card, "
                                + "which anyone can preview — on Discord or here."
                        ) { shareRequest = ThemeShareRequest(theme: SharedClientTheme(sharing: seed)) }
                        .disabled(model.connectionState != .ready)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.cardContentInset)
            .padding(.top, Spacing.snug)

            PlumageAccentRow(
                seed: seed,
                followsSystemAccent: theme.customFollowsSystemAccent,
                select: selectAccent
            )
            .padding(.horizontal, SettingsMetrics.cardContentInset)
            .padding(.top, Spacing.snug)
            .padding(.bottom, SettingsMetrics.cardContentInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsSurface.card)
        .clipShape(.settingsRect(SettingsMetrics.cardRadius))
        .modal(item: $shareRequest) { request in
            ThemeShareSheet(theme: request.theme) { shareRequest = nil }
        }
    }

    // MARK: Acting

    private func edit(_ transform: @escaping (inout ThemeSeed) -> Void) {
        theme.editCustom(transform)
    }

    /// Opens and closes the gesture window the store uses to decide whether the
    /// *drawn* surfaces should re-lay-out. See `ThemeStore.beginAdjusting`.
    private func setTracking(_ tracking: Bool) {
        guard tracking != isTracking else { return }
        isTracking = tracking
        if tracking { theme.beginAdjusting() } else { theme.endAdjusting() }
    }

    private func selectAccent(_ choice: PlumageAccent) {
        switch choice {
        case .system:
            theme.setCustomFollowsSystemAccent(true)
        case .turn(let turn):
            theme.setCustomFollowsSystemAccent(false)
            theme.editCustom { $0.accentTurn = turn }
        }
    }

    private func shuffle() {
        shuffles += 1
        let next = PlumageShuffle.next(after: seed)
        theme.setCustomFollowsSystemAccent(false)
        theme.editCustom { $0 = next }
    }

    /// A new colour **between two others**: the midpoint of its longest leg, at the
    /// hue and depth the walk already has there. The ground does not move until
    /// the reader moves the new bead — adding a colour is a place to pull from,
    /// not a change they did not ask for.
    private func addColour() {
        let insertion = PlumageStop.widestLeg(in: seed)
        let from = seed.position(ofAnchor: insertion)
        let to = seed.position(ofAnchor: insertion + 1)
        let stop = seed.stop(at: (from + to) / 2)
        edit { $0.middle.insert(stop, at: insertion) }
        active = .middle(insertion)
    }

    private func removeColour() {
        guard !seed.middle.isEmpty else { return }
        let removed: Int
        if case .middle(let index) = active, seed.middle.indices.contains(index) {
            removed = index
        } else {
            removed = seed.middle.count - 1
        }
        edit { $0.middle.remove(at: removed) }
        // The bead that was next along the walk takes the selection, so the
        // keys go on moving something near where the reader was looking.
        active = removed < seed.middle.count ? .middle(removed) : .foot
    }
}

// MARK: - The field

/// Which colour a gesture or a key press is moving.
///
/// **By role, not by index**, so the selection survives the walk changing
/// shape: adding a colour between the ends leaves the foot the foot, where an
/// index would quietly have moved the selection onto the new bead.
enum PlumageStop: Hashable, Sendable {
    case head
    /// The colour at this index of `ThemeSeed.middle`.
    case middle(Int)
    case foot

    /// Where this stop sits in `ThemeSeed.anchors`, clamped to the stops the
    /// seed actually has — a middle colour that was just removed falls to the
    /// foot rather than to nothing.
    func index(in seed: ThemeSeed) -> Int {
        switch self {
        case .head: 0
        case .middle(let index) where seed.middle.indices.contains(index): index + 1
        case .middle, .foot: seed.middle.count + 1
        }
    }

    static func at(_ index: Int, in seed: ThemeSeed) -> PlumageStop {
        if index <= 0 { return .head }
        if index > seed.middle.count { return .foot }
        return .middle(index - 1)
    }

    /// The next stop along the walk, wrapping from the foot back to the head.
    func next(in seed: ThemeSeed) -> PlumageStop {
        .at((index(in: seed) + 1) % seed.anchors.count, in: seed)
    }

    func label(in seed: ThemeSeed) -> String {
        switch Self.at(index(in: seed), in: seed) {
        case .head: "Head"
        case .middle(let index): "Colour \(index + 2) of \(seed.anchors.count)"
        case .foot: "Foot"
        }
    }

    /// The leg of the walk that spans the most hue — where a new colour has the
    /// most room to be different from its neighbours.
    static func widestLeg(in seed: ThemeSeed) -> Int {
        let anchors = seed.anchors
        return anchors.indices.dropLast().max { a, b in
            PlumageShuffle.separation(anchors[a].hue, anchors[a + 1].hue)
                < PlumageShuffle.separation(anchors[b].hue, anchors[b + 1].hue)
        } ?? 0
    }
}

private struct PlumageField: View {
    var seed: ThemeSeed
    var isTracking: Bool
    @Binding var active: PlumageStop
    var edit: (@escaping (inout ThemeSeed) -> Void) -> Void
    var trackingChanged: (Bool) -> Void

    @Environment(\.motion) private var motion
    /// How far past an edge the pointer has pulled, in points. Drives the
    /// moving bead's overshoot only — the seed is clamped regardless.
    @State private var overshoot: CGSize = .zero
    /// Where the press landed relative to the bead it took — zero for a press
    /// on bare sheet, which brings the bead to the pointer.
    @State private var grab: CGSize = .zero
    @FocusState private var isFocused: Bool

    static let height: CGFloat = 152
    private static let radius: CGFloat = 13
    fileprivate static let beadSide: CGFloat = 26
    /// One arrow key press. A degree is imperceptible and a tenth of the field
    /// is a jump; this crosses the whole wheel in thirty presses.
    private static let keyStepHue: Double = 12
    private static let keyStepDepth: Double = 0.04

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            PlumageMesh()
                .equatable()
                .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(isFocused ? 0.45 : 0.12), lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(seed.anchors.indices, id: \.self) { index in
                            bead(.at(index, in: seed), in: size)
                        }
                    }
                }
                .contentShape(.rect)
                .gesture(drag(in: size))
        }
        .frame(height: Self.height)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        // `.tab` is deliberately absent: it belongs to the window's own focus
        // ring and has to keep meaning "leave this control".
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .space]) { press in
            switch press.key {
            case .leftArrow: move(hue: -Self.keyStepHue)
            case .rightArrow: move(hue: Self.keyStepHue)
            case .upArrow: move(depth: -Self.keyStepDepth)
            case .downArrow: move(depth: Self.keyStepDepth)
            // Space rather than Tab, which belongs to the window's own focus
            // ring and must keep meaning "leave this control".
            case .space: active = active.next(in: seed)
            default: return .ignored
            }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Ground colours")
        .accessibilityValue(value)
        .accessibilityHint("Arrow keys move the selected colour. Space moves to the next one.")
        .accessibilityAdjustableAction { direction in
            move(hue: direction == .increment ? Self.keyStepHue : -Self.keyStepHue)
        }
    }

    private var value: String {
        let stop = seed.anchors[active.index(in: seed)]
        return "\(active.label(in: seed)) selected. "
            + "Hue \(Int(stop.hue.rounded())) degrees, "
            + "depth \(Int((stop.depth * 100).rounded())) percent."
    }

    // MARK: Reading and writing one stop

    private func write(_ which: PlumageStop, hue: Double, depth: Double) {
        edit { seed in
            seed.setAnchor(which.index(in: seed), to: ThemeStop(hue: hue, depth: depth))
        }
    }

    /// An arrow key's step — stopping at the sheet's ends, as a drag does.
    private func move(hue: Double = 0, depth: Double = 0) {
        let current = seed.anchors[active.index(in: seed)]
        write(active, hue: Self.held(current.hue + hue), depth: current.depth + depth)
    }

    /// A hue held inside the sheet. **Just short of 360**, because a stop
    /// wraps its hue and 360 is 0 — the bead would land on the other edge.
    private static func held(_ hue: Double) -> Double {
        min(Self.lastHue, max(0, hue))
    }

    private static let lastHue = 359.9

    // MARK: Geometry

    private func point(_ which: PlumageStop, in size: CGSize) -> CGPoint {
        let stop = seed.anchors[which.index(in: seed)]
        return CGPoint(x: stop.hue / 360 * size.width, y: stop.depth * size.height)
    }

    // MARK: The beads

    /// A glass ring showing the ground this stop selects.
    ///
    /// **The ground, not the sheet colour underneath it.** The sheet is drawn at
    /// a fixed, legible lightness so its hues are pickable at all — see
    /// `PlumageMesh` — while a bead's own disc is the real derived surface at the
    /// lightness the track is holding, at the stop's own place along the line.
    /// That is the division of labour between them: the sheet says which
    /// colour, the bead says how dark.
    private func bead(_ which: PlumageStop, in size: CGSize) -> some View {
        let origin = point(which, in: size)
        let index = which.index(in: seed)
        let isActive = index == active.index(in: seed)
        let side = Self.beadSide * Self.scale(of: which)
        return Circle()
            .fill(Color(hex: seed.field(at: seed.position(ofAnchor: index)).packedRGB()))
            .frame(width: side * 0.46, height: side * 0.46)
            .frame(width: side, height: side)
            // `.clear` because what is under it is content — the field is the
            // media here, and `.regular` would frost the very colour the bead is
            // pointing at into grey. §4.
            .glassEffect(.clear.interactive(), in: .circle)
            .shadow(color: .black.opacity(0.38), radius: 5, y: 2)
            .offset(
                x: origin.x + (isActive ? overshoot.width : 0) - side / 2,
                y: origin.y + (isActive ? overshoot.height : 0) - side / 2
            )
            // The one being moved is drawn over the others, so a bead dragged
            // across another is never hidden under it mid-gesture.
            .zIndex(isActive ? 1 : 0)
            // Declared here rather than at the writer: §3 forbids wrapping a
            // store write the whole window observes in `withAnimation`, because
            // that opens a global transaction and everything that re-lays-out
            // while it runs animates too. Suppressed entirely while a pointer is
            // down, or a bead would settle toward a target the pointer has
            // already left.
            .animation(isTracking ? nil : motion.reposition, value: seed)
            .animation(motion.standard, value: overshoot)
            .animation(motion.hover, value: isActive)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The LIT end is the largest bead: it is the end that carries the theme's
    /// colour, and the one the accent comes from. The colours between are the
    /// smallest — they shape the walk rather than end it.
    private static func scale(of which: PlumageStop) -> CGFloat {
        switch which {
        case .foot: 1
        case .head: 0.86
        case .middle: 0.74
        }
    }

    // MARK: The gesture

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if !isTracking {
                    // **Chosen on press, then held for the whole drag.** Picking
                    // the nearer bead on every event instead would hand the
                    // gesture to another stop the moment the two crossed,
                    // which is precisely when somebody is dragging one past
                    // another.
                    active = nearestStop(to: value.startLocation, in: size)
                    // **From where it was grabbed**: a press on the bead keeps
                    // its offset, so the bead does not jump its own radius
                    // under the pointer; a press on bare sheet brings it there.
                    let centre = point(active, in: size)
                    let offset = CGSize(
                        width: centre.x - value.startLocation.x,
                        height: centre.y - value.startLocation.y
                    )
                    let onBead = (offset.width * offset.width + offset.height * offset.height).squareRoot()
                        <= Self.beadSide / 2
                    grab = onBead ? offset : .zero
                    trackingChanged(true)
                }
                let target = CGPoint(x: value.location.x + grab.width, y: value.location.y + grab.height)
                // **Held at every edge, never wrapped and never stopped dead** —
                // §3. The stop takes the clamped value; the bead takes the
                // resisted one, so the control says "there is nothing more
                // here" rather than "I have stopped answering".
                let resistedX = Motion.clampWithResistance(target.x, to: 0...size.width, limit: size.width)
                let resistedY = Motion.clampWithResistance(target.y, to: 0...size.height, limit: size.height)
                let clampedX = min(size.width, max(0, target.x))
                let clampedY = min(size.height, max(0, target.y))
                overshoot = CGSize(width: resistedX - clampedX, height: resistedY - clampedY)
                write(
                    active,
                    hue: Self.held(clampedX / size.width * 360),
                    depth: clampedY / size.height
                )
            }
            .onEnded { _ in
                overshoot = .zero
                grab = .zero
                trackingChanged(false)
            }
    }

    /// The stop a press belongs to: the nearest bead on the sheet as drawn.
    private func nearestStop(to location: CGPoint, in size: CGSize) -> PlumageStop {
        func distance(to which: PlumageStop) -> CGFloat {
            (location - point(which, in: size)).length
        }
        return seed.anchors.indices
            .map { PlumageStop.at($0, in: seed) }
            .min { distance(to: $0) < distance(to: $1) } ?? .foot
    }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    var length: CGFloat { (x * x + y * y).squareRoot() }
}

// MARK: - The sheet of candidate grounds

/// The sheet the beads stand on: hue across, depth down.
///
/// **It does not follow the light track, and that is a correction.** The first
/// version drew the reading surface exactly, at whatever lightness the theme was
/// currently set to — which is honest and unusable: a ground at Oklab L 0.15 is
/// very nearly black, so at the dark end of the track the sheet was a black
/// rectangle and there was no hue in it to pick. A picker you cannot see is a
/// worse lie than one that is a shade brighter than the answer.
///
/// So the sheet is the hue-and-depth *space* rather than any one theme's slice
/// of it, drawn once at a lightness chosen to be pickable, and each bead's own
/// disc then shows the exact colour that stop selects at the exact lightness the
/// track is holding. **The sheet says which colour; the beads say how dark.**
///
/// It is still this app's colour and not a hue wheel's. `sheetLightness` tops out
/// well below the middle and `sheetChroma` well below the display's edge, so what
/// the reader is dragging across is a plane of deep, dark colour — the register
/// every one of the ten themes lives in — rather than a strip of neon that
/// promises something the ground cannot deliver.
///
/// The consequence is that it is a constant. Fifty-two derivations, run once for
/// the life of the process; dragging a bead, the track or the shuffle moves
/// nothing in here at all.
private struct PlumageMesh: View, Equatable {
    /// Grey at the top of the sheet, colour at the foot — and darker at the top,
    /// so the plane is lit the way every other surface in this app is.
    private static let sheetLightness: ClosedRange<Double> = 0.245...0.375
    /// Rich enough to tell two neighbouring hues apart at a glance, and short of
    /// the chroma that would make this look like a paint chart.
    private static let sheetChroma = 0.155

    /// Thirteen columns of hue at thirty degrees, four rows of depth.
    ///
    /// The mesh interpolates in sRGB, so the accuracy of the sheet is set by how
    /// close together the real samples are. Thirty degrees is where the error
    /// stops being visible at this size; going finer costs colours and buys
    /// nothing anybody can see.
    private static let columns = 13
    private static let rows = 4

    private static let points: [SIMD2<Float>] = (0..<rows).flatMap { row in
        (0..<columns).map { column in
            SIMD2(
                Float(column) / Float(columns - 1),
                Float(row) / Float(rows - 1)
            )
        }
    }

    private static let colors: [Color] = (0..<rows).flatMap { row in
        let depth = Double(row) / Double(rows - 1)
        let lightness = sheetLightness.lowerBound
            + depth * (sheetLightness.upperBound - sheetLightness.lowerBound)
        return (0..<columns).map { column in
            let hue = Double(column) / Double(columns - 1) * 360
            return Color(hex: Oklch(
                lightness: lightness,
                chroma: depth * sheetChroma,
                hue: hue
            ).packedRGB())
        }
    }

    var body: some View {
        MeshGradient(
            width: Self.columns,
            height: Self.rows,
            points: Self.points,
            colors: Self.colors
        )
    }

    nonisolated static func == (lhs: PlumageMesh, rhs: PlumageMesh) -> Bool { true }
}

// MARK: - The light track

private struct PlumageLightTrack: View {
    var seed: ThemeSeed
    var isTracking: Bool
    var edit: (@escaping (inout ThemeSeed) -> Void) -> Void
    var trackingChanged: (Bool) -> Void

    @Environment(\.motion) private var motion
    @State private var overshoot: CGFloat = 0

    static let height: CGFloat = 30
    private static let knobSide: CGFloat = 24
    private static let keyStep: Double = 0.04

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // The track IS the ramp it selects from: nine samples of the
            // reading surface across the whole light range, at this theme's own
            // hue and depth. A grey slider beside a coloured field would be a
            // control that does not say what it does.
            Capsule()
                .fill(
                    LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                )
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .overlay(alignment: .leading) { knob(in: size) }
                .contentShape(.capsule)
                .gesture(drag(in: size))
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("Ground lightness")
        .accessibilityValue("\(Int((seed.light * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: edit { $0.light += Self.keyStep }
            case .decrement: edit { $0.light -= Self.keyStep }
            @unknown default: break
            }
        }
    }

    /// The track's own gradient: this theme's ground at nine lightnesses.
    ///
    /// Drawn at the lit stop, which is the end the reader is most likely to be
    /// judging — and the brighter of the two, so the track shows the range it
    /// selects from rather than nine shades of near-black.
    private var stops: [Color] {
        (0..<9).map { step in
            var sample = seed
            sample.light = Double(step) / 8
            return Color(hex: sample.canvasLit.packedRGB())
        }
    }

    private func knob(in size: CGSize) -> some View {
        let travel = max(0, size.width - Self.knobSide)
        return Circle()
            .fill(Color.white.opacity(0.85))
            .frame(width: 6, height: 6)
            .frame(width: Self.knobSide, height: Self.knobSide)
            .glassEffect(.clear.interactive(), in: .circle)
            .shadow(color: .black.opacity(0.32), radius: 4, y: 1)
            .offset(x: seed.light * travel + overshoot)
            .animation(isTracking ? nil : motion.reposition, value: seed.light)
            .animation(motion.standard, value: overshoot)
            .allowsHitTesting(false)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                trackingChanged(true)
                let travel = max(1, size.width - Self.knobSide)
                // The pointer grabs the knob's CENTRE, so the usable travel is
                // inset by half a knob at each end — without that, dragging to
                // the far right leaves the knob a dozen points short of it.
                let x = value.location.x - Self.knobSide / 2
                let resisted = Motion.clampWithResistance(x, to: 0...travel, limit: travel)
                overshoot = resisted - min(travel, max(0, x))
                edit { $0.light = x / travel }
            }
            .onEnded { _ in
                overshoot = 0
                trackingChanged(false)
            }
    }
}

// MARK: - The accent

/// The five relationships an accent may have to the ground.
///
/// **Relationships, not colours.** A free colour well here is what produces a
/// theme whose ground and highlight have never met; every option below is
/// derived from the hue the reader already chose, so the two cannot disagree.
enum PlumageAccent: Hashable, Sendable {
    case system
    case turn(Double)

    /// In the order they are drawn. The three offsets are a sixth of the wheel
    /// either side and the opposite point — near enough to read as related, far
    /// enough to read as a choice.
    static let offered: [PlumageAccent] = [
        .system, .turn(0), .turn(1.0 / 12), .turn(-1.0 / 12), .turn(0.5),
    ]

    var label: String {
        switch self {
        case .system: "System accent"
        case .turn(let turn) where turn == 0: "The lit stop’s own hue"
        case .turn(let turn) where turn > 0 && turn < 0.25: "A sixth of the wheel along"
        case .turn(let turn) where turn < 0: "A sixth of the wheel back"
        case .turn: "Opposite the lit stop"
        }
    }
}

private struct PlumageAccentRow: View {
    var seed: ThemeSeed
    var followsSystemAccent: Bool
    var select: (PlumageAccent) -> Void

    @Environment(\.motion) private var motion

    private static let pipSide: CGFloat = 22

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text("Accent")
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            HStack(spacing: Spacing.base) {
                ForEach(PlumageAccent.offered, id: \.self) { option in
                    Pip(
                        color: color(for: option),
                        isSelected: isSelected(option),
                        label: option.label
                    ) { select(option) }
                }
            }
        }
        .animation(motion.standard, value: followsSystemAccent)
        .animation(motion.standard, value: seed.accentTurn)
    }

    private func isSelected(_ option: PlumageAccent) -> Bool {
        switch option {
        case .system: followsSystemAccent
        case .turn(let turn): !followsSystemAccent && abs(turn - seed.accentTurn) < 0.001
        }
    }

    private func color(for option: PlumageAccent) -> Color {
        switch option {
        case .system:
            Color.accentColor
        case .turn(let turn):
            Color(hex: {
                var sample = seed
                sample.accentTurn = turn
                return sample.accent.packedRGB()
            }())
        }
    }

    private struct Pip: View {
        var color: Color
        var isSelected: Bool
        var label: String
        var select: () -> Void

        @Environment(\.motion) private var motion
        @State private var isHovered = false

        var body: some View {
            Button(action: select) {
                Circle()
                    .fill(color)
                    .frame(width: PlumageAccentRow.pipSide, height: PlumageAccentRow.pipSide)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(isHovered ? 0.5 : 0.16), lineWidth: 1)
                    }
                    .overlay {
                        // Outside the pip, so the ring never eats into the
                        // colour it is marking — the gallery's tiles do the
                        // same, and for the same reason.
                        if isSelected {
                            Circle()
                                .strokeBorder(Ink.primary, lineWidth: ThemeMetrics.ringWidth)
                                .padding(-3)
                        }
                    }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(motion.hover, value: isHovered)
            .animation(motion.glassMorph, value: isSelected)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        }
    }
}

// MARK: - The dial

/// Which way the colours run across the window: a needle pointing where the
/// light goes, from the darkest colour toward the lit one.
///
/// **A dial, not a slider**, because an angle is a direction and a dial is the
/// one control whose position *is* the answer. It turns from a drag anywhere on
/// it — measured around its centre, so the pointer does not have to find a
/// thirty-point knob's edge — and VoiceOver steps it through the compass.
private struct PlumageAngleDial: View {
    var seed: ThemeSeed
    var edit: (@escaping (inout ThemeSeed) -> Void) -> Void
    var trackingChanged: (Bool) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    private static var side: CGFloat { PlumageLightTrack.height }
    /// One VoiceOver step: the eight compass points and the eight between them.
    private static let step: Double = 22.5

    var body: some View {
        ZStack {
            Capsule()
                .fill(isHovered ? Ink.primary : Ink.secondary)
                .frame(width: 2, height: Self.side * 0.34)
                .offset(y: -Self.side * 0.17)
                // Clockwise from "up", which is what CSS means by an angle.
                .rotationEffect(.degrees(seed.angle))
            Circle()
                .fill(Ink.primary)
                .frame(width: 4, height: 4)
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(.circle)
        .glassEffect(.clear.interactive(), in: .circle)
        .gesture(turn)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .help("Which way the colours run across the window. Drag around the dial.")
        .accessibilityElement()
        .accessibilityLabel("Angle")
        .accessibilityValue("\(Int(seed.angle.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            edit { $0.angle += direction == .increment ? Self.step : -Self.step }
        }
    }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                trackingChanged(true)
                let dx = value.location.x - Self.side / 2
                let dy = value.location.y - Self.side / 2
                // The hub itself has no direction; a press dead on it would
                // flick the needle to wherever rounding pointed.
                guard dx * dx + dy * dy > 4 else { return }
                edit { $0.angle = atan2(dx, -dy) * 180 / .pi }
            }
            .onEnded { _ in trackingChanged(false) }
    }
}

// MARK: - The round buttons

/// Minus, plus and shuffle: a glyph on a circle of glass the height of the
/// light track beside them.
private struct PlumageRoundButton: View {
    var systemName: String
    var label: String
    var help: String
    /// How many times it has been pressed, for a glyph that turns half a
    /// revolution per press — so a second press keeps going rather than
    /// snapping back. Zero for one that does not turn.
    var turns = 0
    var action: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(symbol: systemName)
                .font(.system(size: 13, weight: .semibold))
                // The glyph dims when there is nothing to do, not the glass:
                // a material faded as a whole is one of the ways §1.5 paints
                // black.
                .foregroundStyle(!isEnabled ? Ink.tertiary : isHovered ? Ink.primary : Ink.secondary)
                .rotationEffect(.degrees(Double(turns) * 180))
                .frame(width: PlumageLightTrack.height, height: PlumageLightTrack.height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // `.clear`: in-window glass on this app is always clear. §4.
        .glassEffect(.clear.interactive(), in: .circle)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .animation(motion.reposition, value: turns)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }
}

// MARK: - What "random" means here

/// The shuffle's candidates.
///
/// **A theme picked uniformly at random is a bad theme most of the time**, and
/// the failure is not subtle: a hue anywhere in the yellow-greens comes out as
/// dishwater at ground lightness, a depth near zero produces a grey the reader
/// could have got from Graphite, and a light near either end is either a black
/// rectangle or a washed-out slab. So this samples from the ranges that work
/// rather than from the whole space.
///
/// It is deliberately not a curated *list* of blends. A list would be an
/// eleventh, twelfth and thirteenth preset hiding behind a die, and the point of
/// the button is to find somewhere the ten do not already go.
nonisolated enum PlumageShuffle {
    /// The bands of the wheel that make a ground worth reading on.
    ///
    /// The gap from 70° to 100° is the one exclusion, and it is a real one:
    /// olive at Oklab L 0.15 has almost no chroma left to spend and reads as a
    /// dirty grey at every depth. Everything else on the wheel has a dark
    /// version worth having.
    static let hueBands: [ClosedRange<Double>] = [
        0...70, 100...200, 200...275, 275...360,
    ]

    /// Enough colour to be a theme rather than a tint, and not so much that the
    /// ground competes with the content on it. The head carries more than the
    /// foot, which is what makes the wash read as light rather than as a stripe.
    static let headDepthRange: ClosedRange<Double> = 0.62...0.95
    static let footDepthRange: ClosedRange<Double> = 0.40...0.76
    /// Dark enough to still be this app, light enough to differ from the last
    /// one.
    static let lightRange: ClosedRange<Double> = 0.28...0.56
    /// The same relationships the accent row offers, minus the system's — a
    /// shuffle that landed on "keep your own accent" would look like it had done
    /// nothing to the one control it did not touch.
    static let accentTurns: [Double] = [0, 1.0 / 12, -1.0 / 12, 0.5]

    /// How far the foot may sit from the head, in degrees, signed.
    ///
    /// **Analogous, never complementary.** Two hues a quarter of the wheel apart
    /// make a gradient; two hues opposite each other make a *transition*, and a
    /// window whose top is orange and whose bottom is blue reads as two colours
    /// meeting rather than one light moving.
    ///
    /// **Wider than it was, and the walk is why.** The band used to stop at
    /// fifty-two degrees, because the field was a straight line through RGB and
    /// anything wider passed through grey in the middle of the transcript. It is
    /// walked in Oklch now — see `ThemeSeed.field(at:)` — so the middle is the
    /// hue between; the band matches the presets' own spread.
    static let footOffsetRange: ClosedRange<Double> = 60...85

    /// Which way a shuffled blend runs: always a fall toward the composer, from
    /// leaning left to leaning right. A shuffle that could turn the light
    /// upside down would land on a room lit from the toolbar about a third of
    /// the time — reachable on the dial, never by chance.
    static let angleRange: ClosedRange<Double> = 115...205

    /// How far a middle colour may stray from the straight walk: enough to give
    /// the line a turn of its own, not enough to double back on itself.
    static let middleJitter = 14.0

    /// A blend that is not the one already showing.
    ///
    /// **The lit hue is required to move by at least a fifth of the wheel.**
    /// Two consecutive draws can otherwise land eight degrees apart, and a
    /// shuffle button that visibly does nothing is worse than no shuffle button —
    /// it reads as broken rather than as unlucky.
    static func next(
        after current: ThemeSeed,
        using generator: inout some RandomNumberGenerator
    ) -> ThemeSeed {
        var hue = current.head.hue
        // Bounded rather than a `while true`: with four bands and a 72° minimum
        // separation a redraw succeeds with probability well over a half, so
        // eight attempts fail about once in four hundred — and the fallback is
        // simply the opposite point on the wheel, which is guaranteed to satisfy
        // the rule it was trying to meet.
        for _ in 0..<8 {
            let band = hueBands.randomElement(using: &generator) ?? (0...360)
            hue = Double.random(in: band, using: &generator)
            if separation(hue, current.head.hue) >= 72 { break }
        }
        if separation(hue, current.head.hue) < 72 { hue = current.head.hue + 180 }

        let offset = Double.random(in: footOffsetRange, using: &generator)
            * (Bool.random(using: &generator) ? 1 : -1)
        var next = ThemeSeed(
            head: ThemeStop(hue: hue, depth: .random(in: headDepthRange, using: &generator)),
            foot: ThemeStop(
                hue: hue + offset,
                depth: .random(in: footDepthRange, using: &generator)
            ),
            light: .random(in: lightRange, using: &generator),
            accentTurn: accentTurns.randomElement(using: &generator) ?? 0,
            angle: .random(in: angleRange, using: &generator)
        )
        // **As many colours as the reader chose**, placed along the new walk
        // and nudged off it. A shuffle that also changed how many beads there
        // are would undo the one decision the reader made on purpose.
        let count = current.middle.count
        next.middle = (0..<count).map { index in
            let along = next.stop(at: Double(index + 1) / Double(count + 1))
            return ThemeStop(
                hue: along.hue + .random(in: -middleJitter...middleJitter, using: &generator),
                depth: along.depth + .random(in: -0.08...0.08, using: &generator)
            )
        }
        return next
    }

    static func next(after current: ThemeSeed) -> ThemeSeed {
        var generator = SystemRandomNumberGenerator()
        return next(after: current, using: &generator)
    }

    /// The short way round the wheel, in degrees.
    static func separation(_ a: Double, _ b: Double) -> Double {
        let difference = abs(ThemeSeed.wrap(a) - ThemeSeed.wrap(b))
        return min(difference, 360 - difference)
    }
}
