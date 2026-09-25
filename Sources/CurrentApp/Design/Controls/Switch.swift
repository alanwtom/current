import SwiftUI

/// The app's switch.
///
/// macOS's own `Toggle` is the single most recognisable stock control there is —
/// its exact pill, its exact blue, its exact size. This one is smaller and
/// squarer-shouldered, and its knob has some give.
///
/// **The knob stretches.** Press it and it widens toward where it's about to
/// go; let go and its leading edge travels on a quick critically damped spring
/// while its trailing edge follows on a softer one, so it lengthens in flight
/// and rounds back up as it lands — squashing a hair as the back edge catches
/// up. That bounce is the one deliberate exception to the app's
/// critically-damped default here: a switch is the closest thing in a settings
/// pane to a physical object, and a knob that arrives dead-flat feels like a
/// picture of a switch. It is "stretch" in the motion vocabulary; see
/// `StretchSpan` for how two edges get two springs.
///
/// **It is a `Button`**, drawn by a `ButtonStyle`, because the press is what
/// the stretch hangs on and `configuration.isPressed` is the one press signal
/// that doesn't fight the click (see `PressableStyle` for the version that
/// did). It also means the switch can be reached from the keyboard like every
/// other button, which the tap gesture it used to be could not.
///
/// The label is a real label — clicking the text flips the switch, because a
/// 30pt target for a settings row is stingy when the whole row is available.
struct CurrentSwitch: ToggleStyle {
    /// Puts the label after the switch instead of before it. Used in narrow
    /// places like a magnet sheet's "select all".
    var labelTrailing = false

    fileprivate static let width: CGFloat = 30
    fileprivate static let height: CGFloat = 18
    fileprivate static let knob: CGFloat = 14
    /// Inset of the knob from the track's edge.
    fileprivate static let inset: CGFloat = 2
    /// How far a pressed knob reaches toward where it's going.
    fileprivate static let reach: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(SwitchBody(isOn: configuration.isOn, labelTrailing: labelTrailing))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private struct SwitchBody: ButtonStyle {
        let isOn: Bool
        let labelTrailing: Bool

        func makeBody(configuration: Configuration) -> some View {
            Row(configuration: configuration, isOn: isOn, labelTrailing: labelTrailing)
        }
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        let labelTrailing: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false
        /// The knob's two edges, measured from the track's inner leading edge.
        @State private var lo: CGFloat
        @State private var hi: CGFloat
        /// The last on/pressed pair seen. State rather than a property, so a
        /// deferred check reads what is true *now* instead of what was true
        /// when the check was scheduled.
        @State private var latest: Knob?

        init(configuration: ButtonStyleConfiguration, isOn: Bool, labelTrailing: Bool) {
            self.configuration = configuration
            self.isOn = isOn
            self.labelTrailing = labelTrailing
            let rest = Self.rest(isOn)
            _lo = State(initialValue: rest.lo)
            _hi = State(initialValue: rest.hi)
        }

        var body: some View {
            HStack(spacing: Space.m) {
                if !labelTrailing {
                    configuration.label
                        .typeStyle(Typo.label)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: Space.l)
                }
                track
                if labelTrailing {
                    configuration.label
                        .typeStyle(Typo.label)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
            .onChange(of: Knob(on: isOn, pressed: configuration.isPressed)) { old, new in
                move(from: old, to: new)
            }
        }

        private var track: some View {
            Capsule(style: .continuous)
                .fill(trackFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isOn ? .clear : Theme.stroke, lineWidth: Size.hairline)
                )
                .frame(width: CurrentSwitch.width, height: CurrentSwitch.height)
                .overlay {
                    StretchSpan(lo: lo, hi: hi, axis: .horizontal, cross: 0...CurrentSwitch.knob) {
                        Capsule(style: .continuous)
                            .fill(Color.white)
                            // The knob's own shadow, not the track's. Without it
                            // the knob melts into the accent fill when on.
                            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    }
                    .padding(CurrentSwitch.inset)
                }
                .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: isOn)
        }

        /// "On" is the accent, the same colour that means "this is happening"
        /// in the library. One meaning, one hue, across the whole app.
        private var trackFill: Color {
            if isOn {
                return isHovering && isEnabled ? Theme.accent.opacity(0.88) : Theme.accent
            }
            return isHovering && isEnabled ? Theme.fillStrong : Theme.fillMuted
        }

        private struct Knob: Equatable {
            let on: Bool
            let pressed: Bool
        }

        private static func rest(_ on: Bool) -> (lo: CGFloat, hi: CGFloat) {
            let travel = CurrentSwitch.width - CurrentSwitch.inset * 2 - CurrentSwitch.knob
            return on ? (travel, travel + CurrentSwitch.knob) : (0, CurrentSwitch.knob)
        }

        private func move(from old: Knob, to new: Knob) {
            latest = new
            let rest = Self.rest(new.on)
            if reduceMotion {
                withAnimation(Motion.adaptive(Motion.quick, reduceMotion: true)) {
                    lo = rest.lo
                    hi = rest.hi
                }
                return
            }

            if new.on != old.on {
                // Flipped. The leading edge goes first and fast; the trailing
                // one follows on the bouncy spring and overshoots a little,
                // which is the squash as the knob lands.
                let lead = Motion.spring(Motion.stretchLead)
                let trail = Motion.gestureSpring(Motion.stretchTrail)
                if new.on {
                    withAnimation(lead) { hi = rest.hi }
                    withAnimation(trail) { lo = rest.lo }
                } else {
                    withAnimation(lead) { lo = rest.lo }
                    withAnimation(trail) { hi = rest.hi }
                }
            } else if new.pressed, !old.pressed {
                // Pressed: reach toward where it's going.
                withAnimation(Motion.spring(Motion.instant)) {
                    if new.on { lo = rest.lo - CurrentSwitch.reach } else { hi = rest.hi + CurrentSwitch.reach }
                }
            } else if !new.pressed, old.pressed {
                // Released without flipping — a drag off the switch, or the
                // release that can arrive a beat before the toggle does. Wait
                // one `instant` for the toggle to land, and only retract if
                // nothing has changed since: retracting after the flip would
                // throw the knob back to the side it just left.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Motion.instant))
                    guard latest == new else { return }
                    withAnimation(Motion.spring(Motion.quick)) {
                        lo = rest.lo
                        hi = rest.hi
                    }
                }
            }
        }
    }
}

/// A checkbox, for multi-select lists — the file picker in the magnet flow.
///
/// The tick draws itself on rather than appearing: a 120ms path trim, which at
/// this size reads as the box being marked instead of the glyph blinking in.
struct CurrentCheckbox: ToggleStyle {
    /// Neither on nor off — some children selected, some not.
    var isMixed = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, isMixed: isMixed)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let isMixed: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        private var filled: Bool { configuration.isOn || isMixed }

        var body: some View {
            HStack(spacing: Space.m) {
                box
                configuration.label
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                configuration.isOn.toggle()
            }
            .onHover { isHovering = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        /// The accent fills the box from its middle, landing with a small
        /// bounce, and the tick draws on just after — so ticking a box reads as
        /// marking it rather than as the box changing colour.
        private var box: some View {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .fill(isHovering ? Theme.fillStrong : Theme.fillMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .fill(Theme.accent)
                        .scaleEffect(filled || reduceMotion ? 1 : 0.35)
                        .opacity(filled ? 1 : 0)
                        .animation(
                            filled
                                ? Motion.gestureSpring(Motion.quick, reduceMotion: reduceMotion)
                                : Motion.adaptive(Motion.instant, reduceMotion: reduceMotion),
                            value: filled
                        )
                }
                .frame(width: 15, height: 15)
                .overlay {
                    if isMixed {
                        Capsule()
                            .fill(Theme.textOnAccent)
                            .frame(width: 7, height: 1.5)
                    } else {
                        Tick()
                            .trim(from: 0, to: configuration.isOn ? 1 : 0)
                            .stroke(
                                Theme.textOnAccent,
                                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 9, height: 7)
                    }
                }
                .animation(
                    configuration.isOn
                        ? Motion.adaptive(Motion.instant, reduceMotion: reduceMotion).delay(reduceMotion ? 0 : 0.07)
                        : Motion.adaptive(Motion.instant, reduceMotion: reduceMotion),
                    value: configuration.isOn
                )
                .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
        }
    }

    /// Two strokes, hand-placed so the short arm is a third of the long one —
    /// SF Symbols' checkmark is optically centred for text and sits slightly low
    /// inside a box this small.
    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.height * 0.55))
            path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: 0))
            return path
        }
    }
}

extension View {
    /// `Toggle("Pause on battery", isOn: $x).currentSwitch()`
    func currentSwitch(labelTrailing: Bool = false) -> some View {
        toggleStyle(CurrentSwitch(labelTrailing: labelTrailing))
    }

    func currentCheckbox(isMixed: Bool = false) -> some View {
        toggleStyle(CurrentCheckbox(isMixed: isMixed))
    }
}
