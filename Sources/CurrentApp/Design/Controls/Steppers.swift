import SwiftUI

/// A number with a minus and a plus.
///
/// macOS's `Stepper` puts a tiny two-arrow chevron next to a label, which is
/// both hard to hit and hard to read at a glance. This is one well holding the
/// value and its two buttons, so the number and the way to change it are the
/// same object — and the value is tabular and transitioned, so stepping from 9
/// to 10 doesn't shove the buttons sideways.
struct CurrentStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Drawn after the number: "5 at a time", "200 peers".
    var unit: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }

            HStack(spacing: Space.xs) {
                Text("\(value)")
                    .typeStyle(Typo.label)
                    .tabularNumerics()
                    .numericTransition()
                    .foregroundStyle(Theme.text)
                if let unit {
                    Text(unit)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, Space.m)
            .frame(minWidth: 74)

            button("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .frame(height: Size.controlM)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Theme.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
        )
        .animation(Motion.spring(Motion.instant, reduceMotion: reduceMotion), value: value)
        .accessibilityElement()
        .accessibilityLabel(unit.map { "\(value) \($0)" } ?? "\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            default: break
            }
        }
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .iconButton(size: Size.controlM, glyph: 10)
        .disabled(!enabled)
        .accessibilityHidden(true)
    }
}

// MARK: - Slider

/// A slider.
///
/// AppKit's is a thin groove with a round chrome knob and a system-blue fill —
/// one of the last stock controls left in the settings panes. This is a capsule
/// track with a filled portion in the accent and a white knob that grows
/// slightly while being dragged, so the thing under your finger is obvious.
///
/// The knob's growth is the only bouncy thing here: it is being physically
/// dragged, which is exactly the case the app's motion rules allow bounce for.
struct CurrentSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var isHovering = false

    private static let knob: CGFloat = 14
    private static let track: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let span = max(proxy.size.width - Self.knob, 1)
            let fraction = normalized
            let knobX = span * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: Self.track)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: knobX + Self.knob / 2, height: Self.track)

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: Self.knob, height: Self.knob)
                    .scaleEffect(isDragging && !reduceMotion ? 1.15 : (isHovering ? 1.06 : 1))
                    .offset(x: knobX)
            }
            .frame(height: Self.knob)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        // Offset by half a knob so the knob's centre lands under
                        // the cursor rather than its leading edge, which
                        // otherwise makes the whole track feel shifted.
                        set(fraction: (drag.location.x - Self.knob / 2) / span)
                    }
                    .onEnded { _ in
                        withAnimation(Motion.gestureSpring(Motion.quick, reduceMotion: reduceMotion)) {
                            isDragging = false
                        }
                    }
            )
            .animation(Motion.gestureSpring(Motion.instant, reduceMotion: reduceMotion), value: isDragging)
            .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
        }
        .frame(height: Size.controlM)
        .onHover { isHovering = $0 }
        .accessibilityElement()
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            let increment = step ?? (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: set(value: value + increment)
            case .decrement: set(value: value - increment)
            default: break
            }
        }
    }

    private var normalized: Double {
        let width = range.upperBound - range.lowerBound
        guard width > 0 else { return 0 }
        return min(max((value - range.lowerBound) / width, 0), 1)
    }

    private func set(fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        set(value: range.lowerBound + clamped * (range.upperBound - range.lowerBound))
    }

    private func set(value newValue: Double) {
        var resolved = min(max(newValue, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            resolved = (resolved / step).rounded() * step
            resolved = min(max(resolved, range.lowerBound), range.upperBound)
        }
        guard resolved != value else { return }
        value = resolved
    }
}
