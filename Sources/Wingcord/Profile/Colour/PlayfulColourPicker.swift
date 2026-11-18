import AppKit
import SwiftUI
import WingcordCore

/// Wingcord's own colour picker, for the profile editor.
///
/// docs/CLIPS-PRESENCE.md, Phase 9 — Alex: "a custom color picker and not use
/// the native one … cool, unique, playful, for example with haptics". So it is
/// a toy as much as a control:
///
///  - **A blob that is the colour**, with the colour's name beside it —
///    "Bubblegum", "Deep Ocean", "Pastel Mint" — and its hex, which can be
///    typed into. The blob wobbles when a colour lands.
///  - **A pad** for how strong and how bright, with a puck that swells under
///    the finger and bumps the trackpad when it reaches an edge.
///  - **A hue rail with notches.** Fourteen named hues pull the thumb in when
///    it passes close, and each one ticks the trackpad like a dial —
///    `HueDetent`. Between them the rail is free.
///  - **Swatches**: the colours in the reader's own avatar first, then a set,
///    each a pop on the trackpad when chosen; **dice** for a colour somebody
///    would plausibly pick; and the system's **eyedropper**, which samples
///    anything on screen.
///
/// The haptics only say what the screen already shows (`Haptics`). Reduce
/// Motion keeps the controls and drops the wobble.
struct PlayfulColourPicker: View {
    @Binding var colour: UInt32
    /// The colours quantised out of the reader's own artwork — offered first,
    /// because a profile colour is usually chosen to go with the avatar.
    var fromArtwork: [UInt32] = []
    var title: String? = nil

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// **Seeded here, not on appear** — a picker that opened on a placeholder
    /// and then jumped to the colour would flash the wrong puck and the wrong
    /// name for a frame.
    @State private var hsb: HSBColour
    @State private var hexText: String
    @State private var isDraggingPad = false
    @State private var isDraggingHue = false
    /// Bumped whenever a colour *lands* — a swatch, the dice, the end of a
    /// drag — and the blob's wobble is keyed on it.
    @State private var landed = 0
    @State private var detent: HueDetent?
    @State private var isTouchingEdge = false
    /// Where the hue rail's thumb stands, 0…1 — **not** the hue, because red
    /// is at both ends of the rail and a thumb dragged to the right end has to
    /// stay there (`HueDetent.settle`).
    @State private var railPosition: Double
    /// Whether the hex field holds something the reader typed and has not
    /// committed. **Only that is ever committed.** The field used to commit
    /// whatever it held when it lost focus — and it takes focus when the
    /// picker opens, held the colour it opened on while the pad was dragged,
    /// and lost focus when the picker closed: so closing put the old colour
    /// back, and Save saved nothing new (Alex, 2026-10-22).
    @State private var hexIsEdited = false
    @FocusState private var focus: Field?
    /// Whether the arrows have been used — the only time the focused control
    /// wears the accent ring. A ring on every open would read as a selection.
    @State private var drivesWithKeys = false

    private enum Field: Hashable { case pad, rail, hex }

    init(colour: Binding<UInt32>, fromArtwork: [UInt32] = [], title: String? = nil) {
        _colour = colour
        self.fromArtwork = fromArtwork
        self.title = title
        let seeded = HSBColour(rgb: colour.wrappedValue)
        _hsb = State(initialValue: seeded)
        _hexText = State(initialValue: ColourText.hex(colour.wrappedValue))
        _railPosition = State(initialValue: seeded.hue)
    }

    static let width: CGFloat = 272
    private static let padHeight: CGFloat = 156
    private static let puck: CGFloat = 22
    private static let railHeight: CGFloat = 18

    /// Discord's own palette for a profile colour, then a few more — the set
    /// people actually pick from.
    static let presets: [UInt32] = [
        0x58_65_F2, 0xEB_45_9E, 0xED_42_45, 0xF5_7C_31, 0xFE_E7_5C,
        0x57_F2_87, 0x1A_BC_9C, 0x34_98_DB, 0x9B_59_B6, 0x23_27_2A,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header
            pad
            hueRail
            swatches
        }
        .padding(Spacing.margin)
        .frame(width: Self.width)
        // The pad takes the keyboard when the picker opens — the arrows move
        // the puck — rather than the hex field, which selected its text and
        // sat waiting to be typed over.
        .defaultFocus($focus, .pad)
        .onChange(of: colour) { _, incoming in
            // Only a colour from outside re-seeds; our own writes round-trip
            // to the same value and must not throw the hue away.
            guard incoming != hsb.rgb else { return }
            write(HSBColour(rgb: incoming).keepingHue(of: hsb))
        }
    }

    // MARK: The blob, its name, its hex

    private var header: some View {
        HStack(spacing: Spacing.snug) {
            blob
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                }
                Text(ColourText.name(hsb))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                    .contentTransition(.interpolate)
                    .animation(motion.fade, value: ColourText.name(hsb))
                hexField
            }
            Spacer(minLength: 0)
        }
    }

    private var blob: some View {
        Circle()
            .fill(Color(hex: hsb.rgb))
            .overlay {
                // A highlight, so it reads as a drop of paint rather than a
                // flat disc.
                Circle()
                    .fill(.linearGradient(
                        colors: [.white.opacity(0.45), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    ))
                    .padding(5)
                    .blendMode(.plusLighter)
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
            .frame(width: 48, height: 48)
            .shadow(color: Color(hex: hsb.rgb).opacity(0.55), radius: 10, y: 4)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: landed) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                if reduceMotion {
                    LinearKeyframe(1, duration: 0.01)
                } else {
                    SpringKeyframe(1.16, duration: 0.11, spring: .snappy)
                    SpringKeyframe(0.95, duration: 0.13, spring: .snappy)
                    SpringKeyframe(1, duration: 0.24, spring: .bouncy)
                }
            }
            .accessibilityHidden(true)
    }

    private var hexField: some View {
        TextField("Hex", text: Binding(
            get: { hexText },
            set: { typed in
                hexText = typed
                hexIsEdited = true
            }
        ))
        .textFieldStyle(.plain)
        .font(.system(.subheadline, design: .monospaced, weight: .medium))
        .foregroundStyle(InkColor.secondary)
        .focused($focus, equals: .hex)
        .frame(width: 84)
        .onSubmit(commitHex)
        .onChange(of: focus) { previous, now in
            if previous == .hex, now != .hex { commitHex() }
        }
        .accessibilityLabel(Text("Hex colour"))
    }

    /// Takes what the reader typed — and nothing else: a field that merely
    /// shows the colour commits nothing when it loses focus.
    private func commitHex() {
        guard hexIsEdited else { return }
        guard let value = ColourText.parse(hexText) else {
            hexText = ColourText.hex(hsb.rgb)
            hexIsEdited = false
            return
        }
        land(HSBColour(rgb: value).keepingHue(of: hsb))
    }

    // MARK: How strong, how bright

    private var pad: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: HSBColour(hue: hsb.hue, saturation: 1, brightness: 1).rgb))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.linearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.linearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                puck
                    .position(
                        x: hsb.saturation * size.width,
                        y: (1 - hsb.brightness) * size.height
                    )
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDraggingPad { isDraggingPad = true }
                        if drivesWithKeys { drivesWithKeys = false }
                        let x = value.location.x / max(size.width, 1)
                        let y = value.location.y / max(size.height, 1)
                        let outside = x < 0 || x > 1 || y < 0 || y > 1
                        if outside != isTouchingEdge {
                            isTouchingEdge = outside
                            if outside { Haptics.bump() }
                        }
                        var next = hsb
                        next.saturation = min(max(x, 0), 1)
                        next.brightness = 1 - min(max(y, 0), 1)
                        write(next)
                    }
                    .onEnded { _ in
                        isDraggingPad = false
                        isTouchingEdge = false
                        landed += 1
                    }
            )
        }
        .frame(height: Self.padHeight)
        .focusable()
        .focused($focus, equals: .pad)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            // The arrows walk the puck a step at a time; the edges bump.
            drivesWithKeys = true
            var next = hsb
            switch direction {
            case .left: next.saturation -= 0.03
            case .right: next.saturation += 0.03
            case .up: next.brightness += 0.03
            case .down: next.brightness -= 0.03
            @unknown default: return
            }
            let clamped = HSBColour(hue: next.hue, saturation: next.saturation, brightness: next.brightness)
            if clamped.saturation != next.saturation || clamped.brightness != next.brightness { Haptics.bump() }
            write(clamped)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Strength and brightness"))
        .accessibilityValue(Text("\(ColourText.name(hsb)), \(ColourText.hex(hsb.rgb))"))
        .accessibilityAdjustableAction { direction in
            var next = hsb
            next.brightness += direction == .increment ? 0.05 : -0.05
            land(HSBColour(hue: next.hue, saturation: next.saturation, brightness: next.brightness))
        }
    }

    private var puck: some View {
        Circle()
            .fill(Color(hex: hsb.rgb))
            // The keyboard's mark: the ring takes the accent while the arrows
            // drive it.
            .overlay { Circle().strokeBorder(focus == .pad && drivesWithKeys ? Color.accentColor : .white, lineWidth: 3) }
            .frame(width: Self.puck, height: Self.puck)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .scaleEffect(isDraggingPad ? 1.35 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55), value: isDraggingPad)
            .allowsHitTesting(false)
    }

    // MARK: Which colour

    private var hueRail: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // **The rail's 0 and 1 are the centres of its two round ends**, not
            // its edges: a notch at hue 0 drawn at the very edge hung half out
            // of the capsule (Alex's screenshot 18), and so did the thumb. The
            // gradient, the notches, the thumb and the pointer all use this one
            // inset scale, so what is under the thumb is the colour it reports.
            let inset = Self.railHeight / 2
            let usable = max(width - 2 * inset, 1)
            let x = { (fraction: Double) in inset + fraction * usable }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.linearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
                            Color(hex: HSBColour(hue: $0, saturation: 1, brightness: 1).rgb)
                        },
                        startPoint: UnitPoint(x: inset / width, y: 0.5),
                        endPoint: UnitPoint(x: 1 - inset / width, y: 0.5)
                    ))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                // The notches, faintly — the reader can see where the rail will
                // pull before they feel it.
                ForEach(HueDetent.all, id: \.self) { mark in
                    Circle()
                        .fill(.white.opacity(detent == mark ? 0.95 : 0.5))
                        .frame(width: 3, height: 3)
                        .position(x: x(mark.hue), y: Self.railHeight / 2)
                }
                Circle()
                    .fill(Color(hex: HSBColour(hue: hsb.hue, saturation: 1, brightness: 1).rgb))
                    .overlay { Circle().strokeBorder(focus == .rail && drivesWithKeys ? Color.accentColor : .white, lineWidth: 3) }
                    .frame(width: Self.railHeight + 6, height: Self.railHeight + 6)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .scaleEffect(isDraggingHue ? 1.25 : 1)
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55), value: isDraggingHue)
                    .position(x: x(railPosition), y: Self.railHeight / 2)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDraggingHue { isDraggingHue = true }
                        if drivesWithKeys { drivesWithKeys = false }
                        let settled = HueDetent.settle((value.location.x - inset) / usable)
                        if settled.detent != detent {
                            detent = settled.detent
                            if settled.detent != nil { Haptics.tick() }
                        }
                        var next = hsb
                        next.hue = settled.hue
                        // A grey has no hue to show; the first touch of the
                        // rail gives it some.
                        if next.saturation < 0.05 { next.saturation = 0.6 }
                        if next.brightness < 0.05 { next.brightness = 0.8 }
                        write(next, railPosition: settled.position)
                    }
                    .onEnded { _ in
                        isDraggingHue = false
                        landed += 1
                    }
            )
        }
        .frame(height: Self.railHeight)
        .padding(.vertical, 3)
        .focusable()
        .focused($focus, equals: .rail)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            // Notch to notch, as the pointer feels it.
            drivesWithKeys = true
            switch direction {
            case .left: stepHue(by: -1)
            case .right: stepHue(by: 1)
            default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Hue"))
        .accessibilityValue(Text(HueDetent.nearest(to: hsb.hue).name))
        .accessibilityAdjustableAction { direction in
            stepHue(by: direction == .increment ? 1 : -1)
        }
    }

    /// One named hue along — the same notches the pointer feels — ticking.
    private func stepHue(by step: Int) {
        let all = HueDetent.all
        let index = all.firstIndex(of: HueDetent.nearest(to: hsb.hue)) ?? 0
        let next = all[(index + step + all.count) % all.count]
        detent = next
        Haptics.tick()
        write(HSBColour(hue: next.hue, saturation: max(hsb.saturation, 0.5), brightness: max(hsb.brightness, 0.6)))
        landed += 1
    }

    // MARK: Swatches, dice, eyedropper

    private var swatches: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if !fromArtwork.isEmpty {
                swatchRow(Array(fromArtwork.prefix(5)), caption: "From your avatar")
            }
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { swatch($0) }
            }
            HStack(spacing: Spacing.base) {
                Button("Surprise Me", systemImage: "dice.fill", action: surprise)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .help("A colour at random")
                Button("Pick from Screen", systemImage: "eyedropper", action: sample)
                    .labelStyle(.glassCircleIcon)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Pick a colour from anywhere on screen")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
    }

    private func swatchRow(_ colours: [UInt32], caption: String) -> some View {
        HStack(spacing: 6) {
            ForEach(colours, id: \.self) { swatch($0) }
            Text(caption)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.secondary)
                .padding(.leading, Spacing.tight)
        }
    }

    private func swatch(_ value: UInt32) -> some View {
        let isCurrent = value == hsb.rgb
        return Button {
            land(HSBColour(rgb: value).keepingHue(of: hsb))
        } label: {
            Circle()
                .fill(Color(hex: value))
                .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                .padding(isCurrent ? 3 : 0)
                .overlay {
                    if isCurrent { Circle().strokeBorder(InkColor.primary, lineWidth: 2) }
                }
                .frame(width: 21, height: 21)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(ColourText.name(value)), \(ColourText.hex(value))"))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func surprise() {
        var generator = SystemRandomNumberGenerator()
        land(.surprise(using: &generator))
    }

    private func sample() {
        NSColorSampler().show { picked in
            guard let picked, let srgb = picked.usingColorSpace(.sRGB) else { return }
            let value = UInt32((srgb.redComponent * 255).rounded()) << 16
                | UInt32((srgb.greenComponent * 255).rounded()) << 8
                | UInt32((srgb.blueComponent * 255).rounded())
            Task { @MainActor in land(HSBColour(rgb: value).keepingHue(of: hsb)) }
        }
    }

    // MARK: Writing

    /// A colour mid-gesture: drawn at once, written through, no fanfare.
    ///
    /// **The hex always follows**, half-typed or not — a drag, a swatch or the
    /// dice is a newer choice than what was being typed. And the rail's thumb
    /// moves only when the hue did, so a thumb at the right-hand red stays
    /// there while the pad changes the strength.
    private func write(_ next: HSBColour, railPosition position: Double? = nil) {
        hsb = next
        hexText = ColourText.hex(next.rgb)
        hexIsEdited = false
        if let position {
            railPosition = position
        } else if HueDetent.distance(next.hue, railPosition) > 0.0001 {
            railPosition = next.hue
        }
        if colour != next.rgb { colour = next.rgb }
    }

    /// A colour that has landed — a swatch, the dice, a typed hex: written,
    /// wobbled and felt.
    private func land(_ next: HSBColour) {
        write(next)
        landed += 1
        Haptics.pop()
    }
}
