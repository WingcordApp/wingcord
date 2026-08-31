import SwiftUI

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
// TWO BEADS, JOINED BY A THREAD. A theme is two colours — one behind the
// toolbar, one behind the composer and down the sidebar — so the instrument has
// two of everything the eye needs to see that: two beads, each showing the
// ground it selects, and a thread between them drawn in the very gradient they
// make. Drag either. The thread follows, and it is the only preview anybody
// needs of what two hues will look like as one room.
//
// So there is no wheel, no eyedropper and no hex box.
//
// FOUR CONTROLS:
//
//   - **The field.** Two stops, each a hue and a depth, tracked 1:1, wrapping
//     horizontally because hue is circular and rubber-banding vertically
//     because depth is not.
//   - **The light track.** How bright the ground is, drawn as the actual ramp
//     it selects from.
//   - **The accent row.** Five relationships to the head stop, each drawn in the
//     colour it would produce. No sixth picker — an accent that can be any
//     colour at all is how a theme ends up with a ground and a highlight that
//     have never met.
//   - **Shuffle.** A blend that is *good*, not a blend that is random — see
//     `PlumageShuffle`.

struct PlumageCard: View {
    @State private var theme = ThemeStore.shared
    @Environment(\.motion) private var motion
    /// True for as long as a pointer is on one of the two continuous controls.
    /// Suppresses the settle animation so the bead cannot lag the pointer.
    @State private var isTracking = false
    @State private var shuffles = 0

    private var seed: ThemeSeed { theme.customSeed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeaderRow(
                title: "Plumage",
                help: "Two colours make a theme: the larger bead is the lit "
                    + "end, down where the composer is, and the smaller one is "
                    + "the darker end behind the toolbar. Hue across, depth "
                    + "down. Drag either — the thread between them is the "
                    + "gradient they make."
            )

            PlumageField(
                seed: seed,
                isTracking: isTracking,
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
                ShuffleButton(turns: shuffles, action: shuffle)
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
}

// MARK: - The field

/// Which of the two stops a gesture or a key press is moving.
enum PlumageStop: Hashable, Sendable, CaseIterable {
    case head
    case foot

    var label: String {
        switch self {
        case .head: "Head colour, behind the toolbar — the darker end"
        case .foot: "Foot colour, behind the composer — the lit end"
        }
    }

    var other: PlumageStop { self == .head ? .foot : .head }
}

private struct PlumageField: View {
    var seed: ThemeSeed
    var isTracking: Bool
    var edit: (@escaping (inout ThemeSeed) -> Void) -> Void
    var trackingChanged: (Bool) -> Void

    @Environment(\.motion) private var motion
    /// How far past the top or bottom edge the pointer has pulled, in points.
    /// Drives the moving bead's overshoot only — the seed is clamped regardless.
    @State private var overshoot: CGFloat = 0
    /// The stop the pointer grabbed, and the one the arrow keys move. Chosen on
    /// press by proximity, so there is nothing to select first.
    @State private var active: PlumageStop = .foot
    @FocusState private var isFocused: Bool

    static let height: CGFloat = 152
    private static let radius: CGFloat = 13
    private static let beadSide: CGFloat = 26
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
                .overlay(alignment: .topLeading) { thread(in: size) }
                .overlay(alignment: .topLeading) { bead(.foot, in: size) }
                .overlay(alignment: .topLeading) { bead(.head, in: size) }
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
            case .space: active = active.other
            default: return .ignored
            }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Ground colours")
        .accessibilityValue(value)
        .accessibilityHint("Arrow keys move the selected stop. Space switches between them.")
        .accessibilityAdjustableAction { direction in
            move(hue: direction == .increment ? Self.keyStepHue : -Self.keyStepHue)
        }
    }

    private var value: String {
        let stop = self.stop(active)
        return "\(active == .head ? "Head" : "Foot") selected. "
            + "Hue \(Int(stop.hue.rounded())) degrees, "
            + "depth \(Int((stop.depth * 100).rounded())) percent."
    }

    // MARK: Reading and writing one stop

    private func stop(_ which: PlumageStop) -> ThemeStop {
        which == .head ? seed.head : seed.foot
    }

    private func write(_ which: PlumageStop, hue: Double, depth: Double) {
        edit { seed in
            let stop = ThemeStop(hue: hue, depth: depth)
            if which == .head { seed.head = stop } else { seed.foot = stop }
        }
    }

    private func move(hue: Double = 0, depth: Double = 0) {
        let current = stop(active)
        write(active, hue: current.hue + hue, depth: current.depth + depth)
    }

    // MARK: Geometry

    private func point(_ which: PlumageStop, in size: CGSize) -> CGPoint {
        let stop = self.stop(which)
        return CGPoint(x: stop.hue / 360 * size.width, y: stop.depth * size.height)
    }

    // MARK: The beads

    /// A glass ring showing the ground this stop selects.
    ///
    /// **The ground, not the sheet colour underneath it.** The sheet is drawn at
    /// a fixed, legible lightness so its hues are pickable at all — see
    /// `PlumageMesh` — while a bead's own disc is the real derived surface at the
    /// lightness the track is holding. That is the division of labour between
    /// them: the sheet says which colour, the bead says how dark.
    private func bead(_ which: PlumageStop, in size: CGSize) -> some View {
        let origin = point(which, in: size)
        let isActive = which == active
        // The LIT end is the larger bead: it is the end that carries the
        // theme's colour, and the one the accent comes from.
        let side = Self.beadSide * (which == .foot ? 1 : 0.86)
        return Circle()
            .fill(Color(hex: which == .foot ? seed.canvasLit.packedRGB() : seed.canvas.packedRGB()))
            .frame(width: side * 0.46, height: side * 0.46)
            .frame(width: side, height: side)
            // `.clear` because what is under it is content — the field is the
            // media here, and `.regular` would frost the very colour the bead is
            // pointing at into grey. §4.
            .glassEffect(.clear.interactive(), in: .circle)
            .specularEdge(in: Circle(), intensity: isActive ? 0.55 : 0.34)
            .shadow(color: .black.opacity(0.38), radius: 5, y: 2)
            .offset(
                x: origin.x - side / 2,
                y: origin.y + (isActive ? overshoot : 0) - side / 2
            )
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

    /// The line between the two beads, drawn in the gradient they make.
    ///
    /// **It is the preview.** Two dots on a sheet say what two hues are; a thread
    /// drawn out of the actual head and foot colours says what they will look
    /// like *as one ground*, which is the only question the reader is asking.
    ///
    /// Hidden when the two stops are nearly on top of each other, where a
    /// two-point gradient is a smudge under the beads rather than a line.
    @ViewBuilder
    private func thread(in size: CGSize) -> some View {
        let head = point(.head, in: size)
        let foot = point(.foot, in: size)
        let span = (head - foot).length
        if span > Self.beadSide {
            Path { path in
                path.move(to: head)
                path.addLine(to: foot)
            }
            .stroke(
                LinearGradient(
                    colors: [
                        Color(hex: seed.canvas.packedRGB()),
                        Color(hex: seed.canvasLit.packedRGB()),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .overlay {
                // A hairline of white over the thread, because two near-black
                // grounds against a dark sheet is a line nobody can see.
                Path { path in
                    path.move(to: head)
                    path.addLine(to: foot)
                }
                .stroke(Color.white.opacity(0.30), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            .animation(isTracking ? nil : motion.reposition, value: seed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                    // gesture to the other stop the moment the two crossed,
                    // which is precisely when somebody is dragging one past the
                    // other.
                    active = nearestStop(to: value.startLocation, in: size)
                    trackingChanged(true)
                }
                // Hue WRAPS: the field is a cylinder, so dragging off the right
                // edge continues from the left rather than stopping. `ThemeStop`
                // does the wrapping, so nothing here has to remember to.
                let hue = value.location.x / size.width * 360
                // Depth does not wrap and must not stop dead either — §3. The
                // stop takes the clamped value; the bead takes the resisted one,
                // so the control says "there is nothing more here" rather than
                // "I have stopped answering".
                let resisted = Motion.clampWithResistance(
                    value.location.y, to: 0...size.height, limit: size.height
                )
                overshoot = resisted - min(size.height, max(0, value.location.y))
                write(active, hue: hue, depth: value.location.y / size.height)
            }
            .onEnded { _ in
                overshoot = 0
                trackingChanged(false)
            }
    }

    /// The stop a press belongs to.
    ///
    /// Distance is measured with the **hue axis wrapped**, because the field is
    /// a cylinder: a bead at 355° and a press at 5° are ten degrees apart, and a
    /// straight subtraction would call them three hundred and fifty.
    private func nearestStop(to location: CGPoint, in size: CGSize) -> PlumageStop {
        func distance(to which: PlumageStop) -> CGFloat {
            let target = point(which, in: size)
            var dx = abs(location.x - target.x)
            if size.width > 0 { dx = min(dx, size.width - dx) }
            return CGPoint(x: dx, y: location.y - target.y).length
        }
        return distance(to: .head) <= distance(to: .foot) ? .head : .foot
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
            let sample = ThemeSeed(
                head: seed.head,
                foot: seed.foot,
                light: Double(step) / 8,
                accentTurn: seed.accentTurn
            )
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
            .specularEdge(in: Circle(), intensity: 0.42)
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
            Color(hex: ThemeSeed(
                head: seed.head, foot: seed.foot, light: seed.light, accentTurn: turn
            ).accent.packedRGB())
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

// MARK: - Shuffle

private struct ShuffleButton: View {
    /// How many times it has been pressed. The glyph turns half a revolution per
    /// press, so a second press keeps going rather than snapping back.
    var turns: Int
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "shuffle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Ink.primary : Ink.secondary)
                .rotationEffect(.degrees(Double(turns) * 180))
                .frame(width: PlumageLightTrack.height, height: PlumageLightTrack.height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .animation(motion.reposition, value: turns)
        .help("A blend chosen from the combinations that work.")
        .accessibilityLabel("Shuffle")
        .accessibilityHint("Replaces the blend with one chosen at random from the combinations that work.")
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
    /// **Analogous, never complementary.** Two hues a third of the wheel apart
    /// make a gradient; two hues opposite each other make a *transition*, and a
    /// window whose top is orange and whose bottom is blue has a visible green
    /// seam through the middle of the transcript wherever the two meet. Between
    /// eighteen and fifty-two degrees is the band where the pair still reads as
    /// one colour changing rather than as two colours meeting.
    static let footOffsetRange: ClosedRange<Double> = 18...52

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
        return ThemeSeed(
            head: ThemeStop(hue: hue, depth: .random(in: headDepthRange, using: &generator)),
            foot: ThemeStop(
                hue: hue + offset,
                depth: .random(in: footDepthRange, using: &generator)
            ),
            light: .random(in: lightRange, using: &generator),
            accentTurn: accentTurns.randomElement(using: &generator) ?? 0
        )
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
