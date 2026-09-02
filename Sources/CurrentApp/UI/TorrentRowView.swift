import SwiftUI
import CurrentCore

/// One torrent as a piece of content. Readable in about a second:
/// name, state pill, progress bar, and the numbers that matter.
struct TorrentRowView: View {
    let snapshot: TorrentSnapshot
    let record: TorrentRecord?
    let failure: EngineFailure?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.system(size: isCompact ? 12 : 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if snapshot.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Pinned — cleanup will skip this")
                    }
                    Spacer(minLength: 8)
                    trailingStat
                }

                ProgressTrack(
                    fraction: effectiveProgress,
                    tint: barTint,
                    reduceMotion: reduceMotion
                )
                .frame(height: isCompact ? 3 : 4)

                // The third line is what a narrow window can least afford, so
                // compact folds the percentage up into the trailing stat and
                // drops this row entirely rather than truncating everything.
                if !isCompact {
                    HStack(spacing: 0) {
                        detailLine
                            .font(.caption)
                            .tabularNumerics()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        secondaryState
                    }
                }
            }
        }
        .padding(.vertical, isCompact ? 5 : 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Pieces

    private var displayName: String {
        if case .resolving = effectiveState {
            return record?.name ?? snapshot.name
        }
        return snapshot.name
    }

    private var effectiveState: TorrentState {
        if let failure {
            return .failed(failure)
        }
        return snapshot.state
    }

    private var effectiveProgress: Double {
        if case .failed = effectiveState { return snapshot.progress }
        return snapshot.progress
    }

    /// Right-aligned live number: download rate while downloading,
    /// upload rate + ratio while seeding.
    @ViewBuilder
    private var trailingStat: some View {
        switch effectiveState {
        case .downloading:
            HStack(spacing: 6) {
                if isCompact, snapshot.hasMetadata {
                    // Carries the number the dropped detail line used to show.
                    Text(ByteFormatting.progress(snapshot.progress))
                        .foregroundStyle(.secondary)
                }
                Text(ByteFormatting.rate(snapshot.downloadRate))
                    .foregroundStyle(SemanticColor.downloading.opacity(0.9))
            }
        case .seeding:
            HStack(spacing: 5) {
                if snapshot.uploadRate > 1 {
                    Text(ByteFormatting.rate(snapshot.uploadRate))
                        .foregroundStyle(SemanticColor.seeding.opacity(0.9))
                } else {
                    Text("Idle")
                        .foregroundStyle(.tertiary)
                }
            }
        default:
            // Compact drops the line that normally carries state, so the pill
            // moves up here. Otherwise a finished torrent would show nothing
            // at all in a narrow window.
            if isCompact {
                StatePill(state: effectiveState)
            }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        if snapshot.hasMetadata && snapshot.totalBytes > 0 {
            Text("\(ByteFormatting.progress(snapshot.progress)) · \(ByteFormatting.bytes(snapshot.selectedBytes)) of \(ByteFormatting.bytes(snapshot.totalBytes))")
        } else {
            Text("Waiting for details…")
        }
    }

    @ViewBuilder
    private var secondaryState: some View {
        switch effectiveState {
        case .failed(let failure):
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SemanticColor.failure)
        case .downloading:
            if let eta = snapshot.etaSeconds {
                Text("\(ByteFormatting.eta(eta)) left")
            } else {
                Text("Calculating…")
                    .foregroundStyle(.tertiary)
            }
        case .seeding:
            Text("Shared \(ByteFormatting.ratio(snapshot.shareRatio))")
                .foregroundStyle(SwarmHealth(seeds: snapshot.swarm.connectedSeeds) == .rare ? SemanticColor.warning : .secondary)
        case .paused(let origin) where origin == .seedGoalReached:
            Label("Seed goal met", systemImage: "checkmark.seal")
                .foregroundStyle(SemanticColor.complete)
        default:
            StatePill(state: effectiveState)
        }
    }

    private var barTint: Color {
        switch effectiveState {
        case .downloading, .checking: return SemanticColor.downloading
        case .seeding: return SemanticColor.seeding
        case .completed: return SemanticColor.complete
        case .failed: return SemanticColor.failure
        case .resolving, .paused: return Color.secondary.opacity(0.45)
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
