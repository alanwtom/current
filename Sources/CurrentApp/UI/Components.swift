import SwiftUI
import CurrentCore

// MARK: - Progress track

/// The one progress bar used everywhere. Thin, rounded, color = state.
/// Animates only when the change is meaningful (never during scrubbing-fast
/// updates; the bar is cheap enough to stay smooth at 1 Hz).
struct ProgressTrack: View {
    var fraction: Double
    var tint: Color
    var reduceMotion: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(clamped * proxy.size.width, clamped > 0 ? 3 : 0))
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: fraction)
    }
}

// MARK: - State pill

/// Compact state indicator. Color + symbol carry meaning; the word confirms.
struct StatePill: View {
    let state: TorrentState

    var body: some View {
        HStack(spacing: 4) {
            image
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityLabel(accessibilityText)
    }

    private var image: Image {
        switch state {
        case .resolving: return Image(systemName: "sparkle.magnifyingglass")
        case .downloading: return Image(systemName: "arrow.down")
        case .paused: return Image(systemName: "pause.fill")
        case .seeding: return Image(systemName: "arrow.up")
        case .completed: return Image(systemName: "checkmark")
        case .checking: return Image(systemName: "waveform.path.ecg")
        case .failed: return Image(systemName: "exclamationmark.triangle.fill")
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
        case .resolving: return .secondary
        case .downloading: return SemanticColor.downloading
        case .paused: return .secondary
        case .seeding: return SemanticColor.seeding
        case .completed: return SemanticColor.complete
        case .checking: return .secondary
        case .failed: return SemanticColor.failure
        }
    }

    private var accessibilityText: String {
        if case .failed(let failure) = state {
            return "Failed: \(failure.title)"
        }
        return label
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var symbol: String = "tray"
    var title: String
    var message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var shortcutHint: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            VStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
                    .padding(.top, 4)
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stat rows (inspector)

struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .tabularNumerics()
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}

// MARK: - Error disclosure

struct ErrorDetailsDisclosure: View {
    let failure: EngineFailure
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SemanticColor.failure)
                Text(failure.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $expanded) {
                Text(failure.technicalMessage)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Text("Details")
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                .fill(SemanticColor.failure.opacity(0.07))
        )
    }
}

// MARK: - Swarm health card

struct SwarmHealthCard: View {
    let health: SwarmHealth
    let seeds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("\(health.label) · \(seeds) seed\(seeds == 1 ? "" : "s")")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            Text(health.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                .fill(color.opacity(0.06))
        )
    }

    private var color: Color {
        switch health {
        case .healthy: return SemanticColor.complete
        case .moderate: return SemanticColor.warning
        case .rare: return SemanticColor.failure
        }
    }
}
