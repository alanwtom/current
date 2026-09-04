import SwiftUI
import CurrentCore

// MARK: - Progress track

/// The one progress bar used everywhere. Thin, capsule, colour = state.
///
/// It sits in a *well*, so an empty bar reads as an empty container rather than
/// as a lighter bar, and it has an indeterminate mode for a magnet that hasn't
/// resolved yet — so "no progress" and "we don't know yet" stop looking
/// identical.
///
/// It used to carry a soft glow in the fill's own colour. That went when the
/// palette stopped using hue for ordinary states: a coloured glow on a coloured
/// bar was decoration, and a *white* glow on a neutral bar is just a smudge. The
/// bar's length is the information.
///
/// The pulse is opacity only, and nothing here changes the view's size. A
/// progress bar whose *layout* changed on every engine tick is the kind of thing
/// that has killed this app before.
struct ProgressTrack: View {
    var fraction: Double
    var tint: Color
    var reduceMotion: Bool = false
    /// Unknown progress — pulses gently instead of showing a length.
    var indeterminate = false
    /// The unfilled part. Defaults to the value tuned for the library's canvas;
    /// surfaces that float above it need `Theme.trackRaised` instead.
    var track: Color = Theme.track

    @State private var pulsing = false

    var body: some View {
        GeometryReader { proxy in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(track)

                if indeterminate {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(pulsing ? 0.45 : 0.14))
                } else {
                    Capsule(style: .continuous)
                        .fill(tint)
                        // Never narrower than its own corner radius, or a
                        // just-started download shows a sliver with clipped ends.
                        .frame(width: clamped > 0 ? max(clamped * proxy.size.width, 3) : 0)
                }
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: fraction)
        // Colour changes are their own beat: a download turning into a seed
        // shouldn't look like the bar jumped.
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: tint)
        .onAppear {
            guard indeterminate, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: Motion.expressive * 2).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - State chip

/// Compact state indicator. Colour plus glyph carry the meaning; the word
/// confirms it.
///
/// Kept as a tinted chip rather than a coloured word because a list of ten
/// torrents in five states needs the states to be scannable as shapes. The glyph
/// swaps with a symbol-effect replace transition, so pausing a download looks
/// like the chip changing rather than two chips crossfading.
struct StatePill: View {
    let state: TorrentState
    /// Drops the word and keeps the glyph — for the compact layout.
    var glyphOnly = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .contentTransition(.symbolEffect(.replace.offUp))
            if !glyphOnly {
                Text(label)
                    .typeStyle(Typo.caption)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, glyphOnly ? Space.xs : Space.s)
        .frame(height: 17)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.13))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.16), lineWidth: Size.hairline)
        )
        .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: label)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        switch state {
        case .resolving: return "sparkle.magnifyingglass"
        case .downloading: return "arrow.down"
        case .paused: return "pause.fill"
        case .seeding: return "arrow.up"
        case .completed: return "checkmark"
        case .checking: return "waveform.path.ecg"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch state {
        case .resolving: return "Resolving"
        case .downloading: return "Downloading"
        case .paused(let origin):
            switch origin {
            case .seedGoalReached: return "Goal met"
            case .battery: return "On battery"
            default: return "Paused"
            }
        case .seeding: return "Seeding"
        case .completed: return "Done"
        case .checking: return "Checking"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .failed: return Theme.failure
        case .downloading, .checking: return Theme.downloading
        case .seeding: return Theme.seeding
        case .completed: return Theme.complete
        // Not a state so much as the absence of one.
        case .paused, .resolving: return Theme.textTertiary
        }
    }

    private var accessibilityText: String {
        if case .failed(let failure) = state {
            return "Failed: \(failure.title)"
        }
        return label
    }
}

// MARK: - Chip

/// A small neutral tag. Pinned markers, file counts, a policy name.
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .typeStyle(Typo.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.s)
        .frame(height: 17)
        .background(Capsule(style: .continuous).fill(Theme.fillMuted))
    }
}

// MARK: - Spinner

/// An indeterminate spinner.
///
/// `ProgressView()` on macOS draws the system's grey pinwheel, which is both
/// unmistakably stock and slightly ugly at small sizes. This is an arc rotating
/// at a constant rate — a rotation, so it never touches layout.
struct Spinner: View {
    var size: CGFloat = 13
    var tint: Color = Theme.textSecondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(tint, style: StrokeStyle(lineWidth: max(1.4, size / 9), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .opacity(reduceMotion ? 0.6 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .accessibilityLabel("Working")
    }
}

// MARK: - Stat row

/// A label-and-value line, for the inspector.
///
/// The dotted leader is doing real work: it ties a label on the left to a number
/// on the right across a 300pt panel, which otherwise reads as two unrelated
/// columns. It is drawn at 20% so it registers as texture rather than as a line.
struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(label)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            Leader()
            Text(value)
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize()
        }
        .frame(minHeight: 20)
    }

    private struct Leader: View {
        var body: some View {
            Rectangle()
                .fill(Theme.textQuaternary.opacity(0.35))
                .frame(height: Size.hairline)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 3)
        }
    }
}

// MARK: - Callout

/// A tinted block of explanation. The app's one way of saying something
/// important inline — a failure, a rule that fired, a caveat in settings.
struct Callout<Content: View>: View {
    var symbol: String
    var tint: Color = Theme.textSecondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconSmall, weight: .semibold))
                .foregroundStyle(tint)
                // Nudged onto the first line's cap height. Top-aligned glyphs
                // sit visibly high next to 11pt text.
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Space.xs, content: content)
            Spacer(minLength: 0)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: Size.hairline)
        )
    }
}

/// A failure, with the technical message tucked behind a disclosure.
struct ErrorDetailsDisclosure: View {
    let failure: EngineFailure
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.failure) {
            Text(failure.title)
                .typeStyle(Typo.label)
                .foregroundStyle(Theme.failure)
            Text(failure.explanation)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? "Hide details" : "Details")
                }
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, Space.hair)

            if expanded {
                Text(failure.technicalMessage)
                    .font(.monoStyle)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .fill(Theme.well)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Swarm health

struct SwarmHealthCard: View {
    let health: SwarmHealth
    let seeds: Int

    var body: some View {
        Callout(symbol: symbol, tint: color) {
            Text("\(health.label) · \(seeds) seed\(seeds == 1 ? "" : "s")")
                .typeStyle(Typo.label)
                .foregroundStyle(Theme.text)
            Text(health.explanation)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var symbol: String {
        switch health {
        case .healthy: return "person.3.fill"
        case .moderate: return "person.2.fill"
        case .rare: return "person.fill.badge.minus"
        }
    }

    /// Amber rather than red for a rare swarm: it is a thing worth knowing and
    /// acting on, not a failure. Nothing is broken.
    private var color: Color {
        switch health {
        case .healthy: return Theme.complete
        case .moderate: return Theme.textSecondary
        case .rare: return Theme.warning
        }
    }
}

// MARK: - Empty state

/// What a surface shows when it has nothing in it.
///
/// The glyph sits in a soft circular well rather than floating on the
/// background. A 44pt ultralight SF Symbol alone on a large empty area reads as
/// a missing image; giving it a container makes it read as an illustration.
struct EmptyStateView: View {
    var symbol: String = "tray"
    var title: String
    var message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var shortcutHint: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Space.xl) {
            ZStack {
                Circle()
                    .fill(Theme.fillSubtle)
                Circle()
                    .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: Space.s) {
                Text(title)
                    .typeStyle(Typo.title)
                    .foregroundStyle(Theme.text)
                Text(message)
                    .typeStyle(Typo.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }

            if let primaryTitle, let primaryAction {
                VStack(spacing: Space.m) {
                    Button(primaryTitle, action: primaryAction)
                        .currentButton(.primary)
                    if let shortcutHint {
                        KeyHint(shortcutHint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rises once when the surface becomes empty. Not repeated, not looped —
        // an empty state that keeps moving is an empty state you can't ignore.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : Motion.enterOffset)
        .onAppear {
            withAnimation(Motion.spring(Motion.standard, reduceMotion: reduceMotion)) {
                appeared = true
            }
        }
    }
}

// MARK: - Keyboard hint

/// A keyboard shortcut drawn as a key.
///
/// Every keyboard path in the app is visible somewhere, because a shortcut
/// nobody can see is a shortcut nobody uses. Drawing them as keycaps rather than
/// grey text is what makes them read as "press this".
struct KeyHint: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .typeStyle(Typo.caption)
            .tabularNumerics()
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Space.s)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .fill(Theme.fillMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
            )
            .accessibilityLabel("Shortcut \(keys)")
    }
}
