import SwiftUI

struct SegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String?

    var id: Value { value }

    init(_ value: Value, _ title: String, symbol: String? = nil) {
        self.value = value
        self.title = title
        self.symbol = symbol
    }
}

/// A segmented control where the selected pill *slides* between options.
///
/// This is the detail worth the custom control. macOS's segmented picker
/// cross-fades its selection, so choosing "Dark" after "Light" gives you no
/// sense that the two are neighbours on a track. Here the pill travels, which
/// tells you where you came from and where you went — and because it is one
/// `matchedGeometryEffect`, it interpolates size as well as position, so options
/// of different widths still work.
///
/// Keyboard: the whole control takes focus as one unit and ←/→ move the
/// selection, which is what the platform does and what AGENTS.md requires.
struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SegmentOption<Value>]
    /// Hides the labels and shows only glyphs — for tight chrome.
    var iconOnly = false
    /// Stretches segments to share the available width evenly.
    var fill = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Theme.well)
        )
        // Focus brightens this control's own border rather than adding the
        // outer accent ring the fields use. The ring is right for a 190pt
        // search box and far too loud around a 290pt strip — clicking a tab lit
        // up the whole inspector header.
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(
                    isFocused ? Theme.accent.opacity(0.55) : Theme.stroke,
                    lineWidth: Size.hairline
                )
        )
        .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isFocused)
        .focusable()
        // Its own ring is drawn above; the system's would sit outside that one.
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: SegmentOption<Value>) -> some View {
        let isSelected = option.value == selection

        return Button {
            guard !isSelected else { return }
            withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                selection = option.value
            }
        } label: {
            HStack(spacing: Space.s) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Size.iconSmall, weight: .medium))
                }
                if !iconOnly {
                    Text(option.title)
                }
            }
            .typeStyle(Typo.label)
            .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: Size.controlM - 4)
            .padding(.horizontal, iconOnly ? Space.m : Space.l)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(Theme.raised)
                        .shadow(color: Theme.shadow, radius: 3, y: 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
                        )
                        // The one pill, shared across every segment. Swapping
                        // which segment owns it is what makes it travel.
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(Radius.s, active: !isSelected)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func step(_ delta: Int) {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
        let next = max(0, min(options.count - 1, index + delta))
        guard next != index else { return }
        withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
            selection = options[next].value
        }
    }
}

// MARK: - Radio group

/// A vertical list of choices, each with an explanation.
///
/// This replaces `.pickerStyle(.radioGroup)`, which draws system radio dots and
/// gives an explanation nowhere to live — the old Network and Seeding panes both
/// had to put the description in a separate paragraph underneath, so you had to
/// pick an option to find out what it did. Here every choice carries its own
/// sentence, which suits an app whose whole premise is explaining itself.
struct RadioGroup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String, detail: String)]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(options, id: \.value) { option in
                row(option)
            }
        }
    }

    private func row(_ option: (value: Value, title: String, detail: String)) -> some View {
        let isSelected = option.value == selection

        return Button {
            withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                selection = option.value
            }
        } label: {
            HStack(alignment: .top, spacing: Space.l) {
                dot(isSelected)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .typeStyle(Typo.label)
                        .foregroundStyle(Theme.text)
                    Text(option.detail)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: Size.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(Radius.m, active: !isSelected)
        .accessibilityLabel("\(option.title). \(option.detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// The dot scales up from nothing rather than fading, so the selection
    /// reads as landing in the new option.
    private func dot(_ isSelected: Bool) -> some View {
        Circle()
            .strokeBorder(isSelected ? Theme.accent : Theme.strokeStrong, lineWidth: 1.5)
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                    .scaleEffect(isSelected ? 1 : 0.01)
                    .opacity(isSelected ? 1 : 0)
            }
            .animation(Motion.gestureSpring(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
    }
}
