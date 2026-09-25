import SwiftUI
import CurrentCore

/// One torrent as a piece of content. Readable in about a second: name, state,
/// progress, and the numbers that matter.
///
/// Drawn as a card rather than a table row. The old build used
/// `.listStyle(.inset(alternatesRowBackgrounds:))`, which gave the app zebra
/// striping and the system's blue selection band — two of the most
/// unmistakably-stock things a Mac list can do. An inset card with a neutral
/// selected fill reads as content instead of as a spreadsheet, and it leaves the
/// accent free for the one thing that is actually happening.
///
/// **The height is fixed.** Not a stylistic choice: this row carries numbers
/// that change every second, and a row that grows by a point when an ETA
/// appears makes the list — and therefore the window — re-measure on every
/// engine tick. AGENTS.md has the long version of why that is fatal.
struct LibraryRow: View {
    let snapshot: TorrentSnapshot
    let record: TorrentRecord?
    let failure: EngineFailure?
    let isSelected: Bool
    /// The row the keyboard is on. Drawn with an outline so arrowing through
    /// the list is followable even when the selection spans several rows.
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCompactLayout) private var isCompact
    @State private var isHovering = false
    /// The phase this row last settled in, to tell a download *finishing* from
    /// a torrent that was simply restored complete. Nil until the row appears.
    @State private var lastPhase: Phase?
    /// Fire the finish (ripple, tick, light pass) and the failure shake. Only
    /// ever bumped by a transition seen while the row was on screen, so a row
    /// scrolled back into view never replays either.
    @State private var finishes = 0
    @State private var failures = 0

    var body: some View {
        HStack(spacing: Space.l) {
            stateGlyph

            VStack(alignment: .leading, spacing: isCompact ? 3 : Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(displayName)
                        .typeStyle(Typo.heading)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if snapshot.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.textQuaternary)
                            .help("Pinned — cleanup will skip this")
                    }

                    Spacer(minLength: Space.m)
                    // Fixed to its ideal width so the *name* is what gives way
                    // when the window is narrow. Without this the two share the
                    // squeeze and the rate gets clipped by the window edge —
                    // which was exactly what happened in the compact layout,
                    // where the trailing slot carries the ETA as well.
                    trailingStat
                        .fixedSize()
                }

                ProgressTrack(
                    fraction: snapshot.progress,
                    tint: barTint,
                    reduceMotion: reduceMotion,
                    indeterminate: isResolving,
                    flow: barFlow,
                    passTrigger: finishes
                )
                .frame(height: Size.track)

                // The third line is what a narrow window can least afford, so
                // compact folds the state up into the trailing stat and drops
                // this row entirely rather than truncating everything.
                if !isCompact {
                    HStack(spacing: Space.m) {
                        detailLine
                            .typeStyle(Typo.caption)
                            .tabularNumerics()
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: Space.m)
                        secondaryState
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, Space.l)
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? Size.rowCompact : Size.row)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(isSelected ? Theme.strokeStrong : .clear, lineWidth: Size.hairline)
        )
        // The keyboard outline sits outside the card's own border so it never
        // changes the row's size — see `focusRing`.
        .focusRing(isFocused, radius: Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
        .onHover { isHovering = $0 }
        .onAppear { lastPhase = phase }
        // Keyed on the coarse phase, which changes a handful of times in a
        // torrent's life — never on the per-tick snapshot.
        .onChange(of: phase) { _, next in
            if lastPhase == .transferring, next == .done { finishes += 1 }
            if next == .failed, lastPhase != .failed { failures += 1 }
            lastPhase = next
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Pieces

    /// The state glyph: tinted, in a **neutral** well.
    ///
    /// The well itself used to be tinted too, which turned a full list into a
    /// column of filled coloured dots. Colouring only the glyph keeps the state
    /// readable at a glance while leaving the row calm. It stays the same size
    /// in every state so the names below stay aligned.
    ///
    /// **Finishing is the one moment a transfer gets.** When a download
    /// becomes a seed or completes, the arrow drops out of the well, the new
    /// glyph draws itself in, one ripple spreads from the well and one pass of
    /// light crosses the bar. Every other change is the ordinary symbol
    /// replace. The glyph gets a new identity only for a finish — so only a
    /// finish transitions instead of morphing — and whether this change is one
    /// is read from `lastPhase`, which still holds the old phase in the very
    /// update that changes the glyph.
    ///
    /// A failure shakes the well once instead. See the vocabulary in `Motion`.
    private var stateGlyph: some View {
        let size: CGFloat = isCompact ? 20 : 26
        let finishing = lastPhase == .transferring && phase == .done
        return ZStack {
            Circle()
                .fill(Theme.fillSubtle)
            Circle()
                .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
            Image(systemName: glyphSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(glyphTint)
                .contentTransition(.symbolEffect(.replace.offUp))
                .id(finishing ? finishes + 1 : finishes)
                .transition(finishTransition)
        }
        .frame(width: size, height: size)
        .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: glyphSymbol)
        .shake(trigger: failures, reduceMotion: reduceMotion)
        .overlay {
            Ripple(trigger: finishes, tint: glyphTint, from: size, to: size * 2.7)
        }
    }

    /// The arrow falls out of the bottom of the well; the finished glyph
    /// draws on. Reduce Motion keeps a crossfade.
    private var finishTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition(.symbolEffect(.drawOn)),
            removal: .opacity.combined(with: .offset(y: 7))
        )
    }

    /// The row's state at the grain the finish and the shake care about.
    private enum Phase: Equatable {
        case transferring, done, failed, other
    }

    private var phase: Phase {
        switch effectiveState {
        case .downloading: return .transferring
        case .seeding, .completed: return .done
        case .failed: return .failed
        case .resolving, .paused, .checking: return .other
        }
    }

    private var barFlow: ProgressTrack.Flow? {
        ProgressTrack.Flow.of(effectiveState, snapshot: snapshot)
    }

    private var displayName: String {
        if case .resolving = effectiveState {
            return record?.name ?? snapshot.name
        }
        return snapshot.name
    }

    private var effectiveState: TorrentState {
        if let failure { return .failed(failure) }
        return snapshot.state
    }

    private var isResolving: Bool {
        if case .resolving = effectiveState { return true }
        return false
    }

    /// Right-aligned live number: download rate while downloading, upload rate
    /// while seeding. Tabular and transitioned, so a rate climbing from 9 to 10
    /// MB/s reads as the same number moving rather than two numbers swapping.
    @ViewBuilder
    private var trailingStat: some View {
        switch effectiveState {
        case .downloading:
            HStack(spacing: Space.m) {
                // Compact has no second line, so the ETA rides up here next to
                // the rate. Progress stays legible from the bar, which is why
                // that is the number that gets dropped rather than these.
                if isCompact, let eta = snapshot.etaSeconds {
                    Text(ByteFormatting.eta(eta))
                        .foregroundStyle(Theme.textTertiary)
                }
                // Grey on purpose: a rate is data, not a status. Painting it
                // meant every row in a busy library shouted, and a real failure
                // had nothing left to stand out against.
                Text(ByteFormatting.rate(snapshot.downloadRate))
                    .foregroundStyle(Theme.textSecondary)
            }
            .typeStyle(Typo.caption)
            .tabularNumerics()
            .numericTransition()

        case .seeding:
            Group {
                if snapshot.uploadRate > 1 {
                    Text(ByteFormatting.rate(snapshot.uploadRate))
                        .foregroundStyle(Theme.textSecondary)
                        .numericTransition()
                } else {
                    Text("Idle")
                        .foregroundStyle(Theme.textQuaternary)
                }
            }
            .typeStyle(Typo.caption)
            .tabularNumerics()

        default:
            // Compact drops the line that normally carries state, so the chip
            // moves up here. Otherwise a finished torrent would show nothing at
            // all in a narrow window.
            if isCompact {
                StatePill(state: effectiveState, glyphOnly: true, quiet: StatePill.quietInRow(effectiveState))
            }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        if snapshot.hasMetadata && snapshot.totalBytes > 0 {
            Text("\(ByteFormatting.progress(snapshot.progress)) · \(ByteFormatting.bytes(snapshot.selectedBytes)) of \(ByteFormatting.bytes(snapshot.totalBytes))")
                .numericTransition()
        } else {
            Text("Waiting for details…")
        }
    }

    @ViewBuilder
    private var secondaryState: some View {
        switch effectiveState {
        case .failed(let failure):
            HStack(spacing: Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text(failure.title)
            }
            .typeStyle(Typo.caption)
            .foregroundStyle(Theme.failure)
            .lineLimit(1)

        case .downloading:
            Group {
                if let eta = snapshot.etaSeconds {
                    Text("\(ByteFormatting.eta(eta)) left").numericTransition()
                } else {
                    Text("Calculating…").foregroundStyle(Theme.textQuaternary)
                }
            }
            .typeStyle(Typo.caption)
            .tabularNumerics()
            .foregroundStyle(Theme.textTertiary)

        case .seeding:
            Text("Shared \(ByteFormatting.ratio(snapshot.shareRatio))")
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(
                    SwarmHealth(swarm: snapshot.swarm) == .rare
                        ? Theme.warning
                        : Theme.textTertiary
                )

        case .paused(let origin) where origin == .seedGoalReached:
            HStack(spacing: Space.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text("Seed goal met")
            }
            .typeStyle(Typo.caption)
            .foregroundStyle(Theme.complete)

        default:
            StatePill(state: effectiveState, quiet: StatePill.quietInRow(effectiveState))
        }
    }

    // MARK: - Colour

    private var rowFill: Color {
        if isSelected { return isHovering ? Theme.fillStrong : Theme.fillMuted }
        return isHovering ? Theme.fillSubtle : .clear
    }

    /// The row's one statement of state, made twice — here and on the glyph.
    /// The rate beside it stays grey; see the colour policy in `Palette`.
    private var barTint: Color {
        switch effectiveState {
        case .failed: return Theme.failure
        case .downloading, .checking: return Theme.downloading
        case .seeding: return Theme.seeding
        case .completed: return Theme.complete
        case .resolving, .paused: return Theme.progressIdle
        }
    }

    private var glyphTint: Color {
        switch effectiveState {
        case .failed: return Theme.failure
        case .downloading, .checking: return Theme.downloading
        case .seeding: return Theme.seeding
        case .completed: return Theme.complete
        case .resolving: return Theme.textSecondary
        case .paused: return Theme.textTertiary
        }
    }

    private var glyphSymbol: String {
        switch effectiveState {
        case .downloading: return "arrow.down"
        case .checking: return "waveform.path.ecg"
        case .seeding: return "arrow.up"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .resolving: return "sparkle.magnifyingglass"
        case .paused: return "pause.fill"
        }
    }

    private var accessibilityDescription: String {
        var parts = [displayName]
        parts.append(ByteFormatting.progress(snapshot.progress))
        if snapshot.totalBytes > 0 {
            parts.append("\(ByteFormatting.bytes(snapshot.selectedBytes)) of \(ByteFormatting.bytes(snapshot.totalBytes))")
        }
        switch effectiveState {
        case .downloading:
            parts.append("downloading at \(ByteFormatting.rate(snapshot.downloadRate))")
            if let eta = snapshot.etaSeconds { parts.append("\(ByteFormatting.eta(eta)) remaining") }
        case .seeding: parts.append("seeding, shared \(ByteFormatting.ratio(snapshot.shareRatio))")
        case .paused: parts.append("paused")
        case .failed(let failure): parts.append(failure.title)
        default: break
        }
        return parts.joined(separator: ", ")
    }
}
