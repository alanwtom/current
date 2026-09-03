import SwiftUI

/// The app's text field.
///
/// `.textFieldStyle(.roundedBorder)` draws AppKit's bezel — a gradient, an inner
/// shadow and a focus ring in the system accent — and it is unmistakable. This
/// is a flat well with a hairline, and on focus the hairline brightens while a
/// ring grows outside it. Nothing about the field's size changes when it takes
/// focus, which is what stops a settings pane from twitching as you tab through.
struct CurrentField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String?
    var scale: ButtonScale = .regular
    var monospaced = false
    /// Takes the keyboard as soon as it appears.
    ///
    /// Only for fields inside a modal surface, and there it isn't a nicety: the
    /// app's modals are overlays rather than sheets, so nothing hands them first
    /// responder. Left unfocused, the library list keeps the keyboard and its
    /// arrow keys go on moving the selection behind the scrim.
    var autofocus = false
    var onSubmit: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.s) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Size.iconSmall, weight: .medium))
                    // Brightens on focus. A tiny thing, but it makes the icon
                    // part of the control rather than decoration beside it.
                    .foregroundStyle(isFocused ? Theme.textSecondary : Theme.textTertiary)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .monoStyle : Typo.label.font)
                .foregroundStyle(Theme.text)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            trailing()
        }
        .padding(.horizontal, Space.m)
        .frame(height: scale.height)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Theme.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: Size.hairline)
        )
        .focusRing(isFocused, radius: Radius.m)
        .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isFocused)
        .contentShape(Rectangle())
        // Clicking anywhere in the well focuses the field, not just the
        // text itself — the padding is part of the target.
        .onTapGesture { isFocused = true }
        .onAppear {
            // Immediately, not after a delay: `onAppear` fires as the surface's
            // entrance begins, so keystrokes land during the animation rather
            // than after it.
            if autofocus { isFocused = true }
        }
    }
}

extension CurrentField where Trailing == EmptyView {
    init(
        _ placeholder: String,
        text: Binding<String>,
        symbol: String? = nil,
        scale: ButtonScale = .regular,
        monospaced: Bool = false,
        autofocus: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.init(
            placeholder: placeholder,
            text: text,
            symbol: symbol,
            scale: scale,
            monospaced: monospaced,
            autofocus: autofocus,
            onSubmit: onSubmit,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Search

/// A search field with a clear button that appears only when there is something
/// to clear.
///
/// The clear button scales in from nothing rather than fading. At 11pt a fade
/// looks like a rendering glitch; a scale reads as an object arriving.
struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"
    var width: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CurrentField(
            placeholder: placeholder,
            text: $text,
            symbol: "magnifyingglass",
            scale: .regular
        ) {
            if !text.isEmpty {
                Button {
                    withAnimation(Motion.spring(Motion.instant, reduceMotion: reduceMotion)) {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .iconButton(size: 16, glyph: 11)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.4).combined(with: .opacity)
                )
            }
        }
        .frame(width: width)
        .animation(Motion.spring(Motion.instant, reduceMotion: reduceMotion), value: text.isEmpty)
    }
}

// MARK: - Numeric field

/// A number field with its unit inside the well.
///
/// Putting "KB/s" inside the control rather than as a label beside it is what
/// lets the bandwidth pane read as a sentence instead of a form. The value is
/// tabular so typing a digit doesn't shove the unit sideways.
struct NumberField: View {
    @Binding var value: Int
    var unit: String?
    var width: CGFloat = 96
    var range: ClosedRange<Int> = 0...Int.max
    /// Thousands separators. Right for a quantity (1,000 KB/s), wrong for an
    /// identifier — the listening port rendered as "6,881", which looks like a
    /// typo rather than a port number.
    var grouped = true

    @FocusState private var isFocused: Bool

    private var format: IntegerFormatStyle<Int> {
        grouped
            ? .number.precision(.fractionLength(0))
            : .number.precision(.fractionLength(0)).grouping(.never)
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            TextField("", value: clamped, format: format)
                .textFieldStyle(.plain)
                .typeStyle(Typo.label)
                .tabularNumerics()
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
            if let unit {
                Text(unit)
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Space.m)
        .frame(width: width, height: Size.controlM)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Theme.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: Size.hairline)
        )
        .focusRing(isFocused, radius: Radius.m)
    }

    /// Clamping in the binding, not on submit: a port of 900000 should be
    /// impossible to hold in the field at all, rather than accepted and then
    /// silently corrected somewhere else.
    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}
