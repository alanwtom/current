import SwiftUI

/// What a button is for, which is the only thing a caller should have to decide.
///
/// Colour, border, hover and press behaviour all follow from the role, so there
/// is no way to end up with a destructive button that looks secondary. macOS's
/// own `.borderedProminent` / `.bordered` split does roughly this, but it paints
/// with the system accent and the system's control shape — the two most
/// recognisably-stock things in the old build.
enum ButtonKind {
    /// The one action a surface exists for. At most one per surface.
    case primary
    /// A real action that isn't the point of the surface. Bordered, neutral.
    case secondary
    /// Chrome and toolbars — no border until you hover it.
    case ghost
    /// Removal. Reads as dangerous without shouting; the fill only turns red on
    /// hover, so a destructive button at rest doesn't dominate a dialog.
    case destructive
}

enum ButtonScale {
    case small
    case regular
    case large

    var height: CGFloat {
        switch self {
        case .small: return Size.controlS
        case .regular: return Size.controlM
        case .large: return Size.controlL
        }
    }

    var padding: CGFloat {
        switch self {
        case .small: return Space.m
        case .regular: return Space.l
        case .large: return Space.xl
        }
    }

    var radius: CGFloat {
        switch self {
        case .small: return Radius.s
        case .regular, .large: return Radius.m
        }
    }

    var type: TypeStyle {
        switch self {
        case .small: return Typo.caption
        case .regular, .large: return Typo.label
        }
    }
}

/// The app's only button style.
struct CurrentButton: ButtonStyle {
    var role: ButtonKind = .secondary
    var scale: ButtonScale = .regular
    /// Stretches to the available width — for a sheet's confirm button.
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, role: role, scale: scale, fill: fill)
    }

    /// A nested `View` rather than inline, because a `ButtonStyle` can't hold
    /// `@State` and hover needs some.
    struct StyleBody: View {
        let configuration: Configuration
        let role: ButtonKind
        let scale: ButtonScale
        let fill: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .typeStyle(scale.type)
                .foregroundStyle(labelColor)
                .padding(.horizontal, scale.padding)
                .frame(height: scale.height)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: scale.radius, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: scale.radius, style: .continuous)
                        .strokeBorder(border, lineWidth: Size.hairline)
                )
                // The primary button is the one place in the app that gets a
                // shadow on a control. It earns it: a solid filled block with
                // no lift looks pasted on.
                .shadow(
                    color: role == .primary && isEnabled ? Theme.shadow : .clear,
                    radius: 6,
                    y: 2
                )
                .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: scale.radius, style: .continuous))
                .animation(Motion.spring(Motion.instant, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
                .onHover { isHovering = $0 }
        }

        /// Hover lifts, press goes further. Both are one step on the same
        /// ladder, so a button feels like a physical thing being leaned on.
        private var isActive: Bool { isHovering && isEnabled }

        private var background: Color {
            switch role {
            case .primary:
                if configuration.isPressed { return Theme.accent.opacity(0.82) }
                return isActive ? Theme.accent.opacity(0.92) : Theme.accent
            case .secondary:
                if configuration.isPressed { return Theme.fillStrong }
                return isActive ? Theme.fillMuted : Theme.fillSubtle
            case .ghost:
                if configuration.isPressed { return Theme.fillMuted }
                return isActive ? Theme.fillSubtle : .clear
            case .destructive:
                if configuration.isPressed { return Theme.failure.opacity(0.22) }
                return isActive ? Theme.failure.opacity(0.14) : Theme.fillSubtle
            }
        }

        private var border: Color {
            switch role {
            case .primary: return .clear
            case .secondary: return Theme.stroke
            case .ghost: return .clear
            case .destructive: return isActive ? Theme.failure.opacity(0.3) : Theme.stroke
            }
        }

        private var labelColor: Color {
            switch role {
            case .primary: return Theme.textOnAccent
            case .secondary: return Theme.text
            case .ghost: return isActive ? Theme.text : Theme.textSecondary
            case .destructive: return Theme.failure
            }
        }
    }
}

// MARK: - Icon buttons

/// A square button holding one glyph — the chrome bar, an inspector header, a
/// field's clear button.
///
/// Separate from `CurrentButton` because the geometry is different in a way that
/// matters: this one is square and sized from its glyph, so a row of them lines
/// up on a grid, and the hover fill is a rounded square rather than a pill.
struct IconButton: ButtonStyle {
    var size: CGFloat = Size.iconButton
    var glyph: CGFloat = Size.icon
    /// Drawn as "on" — a toggle that is currently engaged.
    var isActive = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(
            configuration: configuration,
            size: size,
            glyph: glyph,
            isActive: isActive,
            isDestructive: isDestructive
        )
    }

    struct StyleBody: View {
        let configuration: Configuration
        let size: CGFloat
        let glyph: CGFloat
        let isActive: Bool
        let isDestructive: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(background)
                )
                .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .animation(Motion.spring(Motion.instant, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
                .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: isActive)
                .onHover { isHovering = $0 }
        }

        private var active: Bool { isHovering && isEnabled }

        private var background: Color {
            if configuration.isPressed { return Theme.fillStrong }
            if isActive { return active ? Theme.fillStrong : Theme.fillMuted }
            return active ? Theme.fillSubtle : .clear
        }

        private var tint: Color {
            if isDestructive { return Theme.failure }
            if isActive { return Theme.text }
            return active ? Theme.text : Theme.textSecondary
        }
    }
}

// MARK: - Convenience

extension View {
    /// `Button("Add") { }.currentButton(.primary)`
    func currentButton(
        _ role: ButtonKind = .secondary,
        scale: ButtonScale = .regular,
        fill: Bool = false
    ) -> some View {
        buttonStyle(CurrentButton(role: role, scale: scale, fill: fill))
    }

    func iconButton(
        size: CGFloat = Size.iconButton,
        glyph: CGFloat = Size.icon,
        isActive: Bool = false,
        isDestructive: Bool = false
    ) -> some View {
        buttonStyle(IconButton(size: size, glyph: glyph, isActive: isActive, isDestructive: isDestructive))
    }
}
