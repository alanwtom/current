import SwiftUI

/// The app's switch.
///
/// macOS's own `Toggle` is the single most recognisable stock control there is —
/// its exact pill, its exact blue, its exact size. This one is smaller and
/// squarer-shouldered, with a knob that travels on a spring. This one is smaller and
/// squarer-shouldered, and the knob travels on a spring with a touch of bounce.
/// That bounce is the one deliberate exception to the app's critically-damped
/// default: a switch is the closest thing in a settings pane to a physical
/// object, and a knob that arrives dead-flat feels like a picture of a switch.
///
/// The label is a real label — clicking the text flips the switch, because a
/// 30pt target for a settings row is stingy when the whole row is available.
struct CurrentSwitch: ToggleStyle {
    /// Puts the label after the switch instead of before it. Used in narrow
    /// places like a magnet sheet's "select all".
    var labelTrailing = false

    private static let width: CGFloat = 30
    private static let height: CGFloat = 18
    private static let knob: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, labelTrailing: labelTrailing)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let labelTrailing: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

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
            .onTapGesture {
                guard isEnabled else { return }
                configuration.isOn.toggle()
            }
            .onHover { hovering in
                withAnimation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        private var track: some View {
            Capsule(style: .continuous)
                .fill(trackFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(configuration.isOn ? .clear : Theme.stroke, lineWidth: Size.hairline)
                )
                .frame(width: CurrentSwitch.width, height: CurrentSwitch.height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        // The knob's own shadow, not the track's. Without it the
                        // knob melts into the accent fill when switched on.
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                        .frame(width: CurrentSwitch.knob, height: CurrentSwitch.knob)
                        .padding(.horizontal, 2)
                }
                // Animating on the alignment change rather than an offset means
                // the geometry stays correct at any track width, and SwiftUI
                // interpolates the position for us.
                .animation(
                    Motion.gestureSpring(Motion.quick, reduceMotion: reduceMotion),
                    value: configuration.isOn
                )
        }

        /// "On" is the accent, the same colour that means "this is happening"
        /// in the library. One meaning, one hue, across the whole app.
        private var trackFill: Color {
            if configuration.isOn {
                return isHovering && isEnabled ? Theme.accent.opacity(0.88) : Theme.accent
            }
            return isHovering && isEnabled ? Theme.fillStrong : Theme.fillMuted
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

        private var box: some View {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .fill(filled ? Theme.accent : (isHovering ? Theme.fillStrong : Theme.fillMuted))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .strokeBorder(filled ? .clear : Theme.stroke, lineWidth: Size.hairline)
                )
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
                    Motion.adaptive(Motion.instant, reduceMotion: reduceMotion),
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
