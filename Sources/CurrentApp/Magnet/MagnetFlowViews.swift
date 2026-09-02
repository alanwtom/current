import SwiftUI
import CurrentCore

// MARK: - Notch surface root

/// Content hosted inside the notch panel. The panel frame is managed by
/// `NotchWindowController`; this view draws whatever the current stage and
/// surface state require, anchored to the very top of the screen so it reads
/// as a physical extension of the camera housing.
struct NotchSurfaceView: View {
    @ObservedObject var controller: NotchWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        // The top of this panel is flush with the top of the screen, which on a
        // notched Mac is behind the camera housing. Drawing there is invisible
        // in real life but still captured in screenshots, so it looks like the
        // panel is "just black" while a screen capture shows the text fine.
        // Content starts below the housing.
        .padding(.top, controller.notchHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            // Square at the top so it meets the screen edge seamlessly, rounded
            // below so it reads as the notch growing rather than a black box
            // parked over the desktop.
            UnevenRoundedRectangle(
                bottomLeadingRadius: plateCornerRadius,
                bottomTrailingRadius: plateCornerRadius,
                style: .continuous
            )
            .fill(controller.surfaceState == .hidden ? Color.clear : Color.black)
        )
        .animation(Motion.spring(reduceMotion: reduceMotion), value: animationToken)
        .clipped()
    }

    /// Hidden state has to stay a plain rectangle so it matches the hardware
    /// notch exactly and disappears into it.
    private var plateCornerRadius: CGFloat {
        controller.surfaceState == .hidden ? 0 : Layout.cornerL
    }

    private var animationToken: Int {
        switch controller.surfaceState {
        case .hidden: return 0
        case .pill: return 1
        case .dropTarget: return 3
        case .card:
            return controller.isDetailExpanded ? 5 : 4
        }
    }

    @ViewBuilder
    private var content: some View {
        // Nothing is built while collapsed. Clipping alone would hide it, but
        // there's no reason to keep laying out a view that can never be seen —
        // and in this app, per-tick layout work in a window is exactly what has
        // crashed it before.
        if controller.surfaceState == .hidden {
            EmptyView()
        } else if controller.flowStage != .idle || controller.selectionSummary != nil {
            flowContent
        } else if controller.summary != nil || controller.featured != nil {
            // `summary` matters on its own here: a library that is finished and
            // seeding still has something to report, but has no single
            // "featured" torrent to point at.
            activityContent
        }
    }

    @ViewBuilder
    private var flowContent: some View {
        switch controller.flowStage {
        case .resolving(let hint, let startedAt):
            if controller.surfaceState == .pill {
                ResolvingPill(hint: hint, anchoredToNotch: true)
            } else {
                ResolvingCard(hint: hint, startedAt: startedAt) {
                    Task { await controller.app?.cancelMagnetSelection() }
                }
            }
        case .selecting:
            if let summary = controller.selectionSummary {
                SelectionSummaryCard(
                    summary: summary,
                    onChooseFiles: { controller.onChooseFiles() },
                    onConfirm: { controller.onConfirmSelection(summary.totalBytes) },
                    onCancel: { Task { await controller.app?.cancelMagnetSelection() } }
                )
            }
        case .starting:
            StartingIndicator()
        case .completed(let name):
            CompletionBadge(name: name)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        if controller.surfaceState == .pill {
            // The collapsed strip reports the whole queue, not one torrent.
            if let summary = controller.summary {
                ActivityAmbientPill(summary: summary)
            }
        } else if let featured = controller.featured {
            ActivityCard(
                featured: featured,
                isPaused: false,
                onPause: { controller.onPauseFeatured() },
                onReveal: { controller.onRevealFeatured() }
            )
            .onTapGesture {
                withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                    controller.isDetailExpanded.toggle()
                }
            }
        }
    }
}

// MARK: - Shared stage views

/// The app mark, small. Same silhouette as the app icon — narrowing current
/// lines ending in a drop — so the notch strip is recognisably this app.
///
/// Bars rather than waves on purpose: at 15pt the icon's wave crests are well
/// under a pixel and just make the shape look furry. The icon's own 16pt
/// artwork flattens for the same reason.
struct CurrentMark: View {
    var tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Capsule().frame(width: 15, height: 2.5)
            Capsule().frame(width: 10, height: 2.5)
            Capsule().frame(width: 5.5, height: 2.5)
            Circle().frame(width: 2.5, height: 2.5)
        }
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

/// The collapsed notch strip: what's happening, in one glance.
struct ActivityAmbientPill: View {
    let summary: NotchWindowController.LibrarySummary

    private var tint: Color {
        switch summary.dominant {
        case .downloading: return SemanticColor.downloading
        case .seeding: return SemanticColor.seeding
        case .complete: return SemanticColor.complete
        case .failed: return SemanticColor.failure
        }
    }

    /// Upload rate when seeding, download rate otherwise — the number that
    /// matters for the state the strip is currently reporting.
    private var rate: Double {
        summary.dominant == .seeding ? summary.uploadRate : summary.downloadRate
    }

    var body: some View {
        HStack(spacing: 7) {
            CurrentMark(tint: tint)

            Text("\(summary.done)/\(summary.total)")
                .font(.caption2.weight(.semibold))
                .tabularNumerics()
                .foregroundStyle(.white.opacity(0.92))

            if rate > 1 {
                Text(ByteFormatting.rate(rate))
                    .font(.caption2)
                    .tabularNumerics()
                    .foregroundStyle(tint)
                    // Pinned so a rate crossing KB/s -> MB/s can't resize the
                    // strip. A notch that twitches once a second is worse than
                    // no notch at all.
                    .frame(width: 62, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(summary.done) of \(summary.total) complete"
                + (rate > 1 ? ", \(ByteFormatting.rate(rate))" : "")
        )
    }
}

struct ResolvingPill: View {
    let hint: String?
    var anchoredToNotch = true

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .tint(anchoredToNotch ? .white.opacity(0.8) : .secondary)
            Text("Resolving magnet…")
                .font(.caption.weight(.medium))
                .foregroundStyle(anchoredToNotch ? Color.white.opacity(0.85) : Color.primary.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct ResolvingCard: View {
    let hint: String?
    let startedAt: Date
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(hint ?? "Resolving magnet…")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Cancel")
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                Text(elapsed > 15 ? "Still looking — this can take a minute" : "Contacting peers for file details")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(14)
    }
}

struct SelectionSummaryCard: View {
    let summary: NotchWindowController.SelectionSummary
    var onChooseFiles: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(summary.fileCount) files · \(ByteFormatting.bytes(summary.totalBytes))")
                        .font(.caption)
                        .tabularNumerics()
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Cancel")
            }

            HStack(spacing: 8) {
                Button("Choose files…") { onChooseFiles() }
                    .controlSize(.small)
                Spacer()
                Button {
                    onConfirm()
                } label: {
                    Text("Download \(ByteFormatting.bytes(summary.totalBytes))")
                        .tabularNumerics()
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

struct StartingIndicator: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("Starting download…")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct CompletionBadge: View {
    let name: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SemanticColor.complete)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 0) {
                Text("Download complete")
                    .font(.callout.weight(.semibold))
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download complete: \(name)")
    }
}

struct ActivityCard: View {
    let featured: NotchWindowController.FeaturedTorrent
    var isPaused: Bool
    var onPause: () -> Void
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(featured.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            ProgressTrack(fraction: featured.progress, tint: Color.accentColor)
                .frame(height: 4)

            HStack(spacing: 12) {
                Label(ByteFormatting.rate(featured.downloadRate), systemImage: "arrow.down")
                Label(ByteFormatting.rate(featured.uploadRate), systemImage: "arrow.up")
                Spacer()
                if let eta = featured.etaSeconds {
                    Text("\(ByteFormatting.eta(eta)) left")
                }
            }
            .font(.caption.tabularNumerics())
            .foregroundStyle(.white.opacity(0.65))

            HStack(spacing: 8) {
                Button(isPaused ? "Resume" : "Pause") { onPause() }
                    .controlSize(.small)
                Button("Reveal") { onReveal() }
                    .controlSize(.small)
                Spacer()
            }
            .tint(.white)
        }
        .padding(14)
    }
}

// MARK: - Drop target content (drawn while a drag session is over the notch)

struct DropTargetBadge: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 20, weight: .light))
            Text("Drop to add")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(0.35))
                .padding(6)
        )
        .background(Color.black)
    }
}

// MARK: - In-window fallback overlay

/// Same interaction stages presented inside the main window when there's no
/// notch (or the feature is off). Never blocks the library; dismisses cleanly.
struct MagnetFlowOverlayView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var flow: MagnetFlowCenter
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            switch flow.stage {
            case .resolving(let hint, let startedAt):
                card {
                    ResolvingCard(hint: hint, startedAt: startedAt) {
                        Task { await app.cancelMagnetSelection() }
                    }
                }
            case .selecting:
                if let id = selectingID, let metadata = store.metadataCache[id] {
                    card {
                        SelectionSummaryCard(
                            summary: .init(
                                id: id,
                                name: metadata.displayName,
                                fileCount: metadata.files.count,
                                totalBytes: metadata.totalSize
                            ),
                            onChooseFiles: { app.showMagnetFilePicker = true },
                            onConfirm: {
                                Task {
                                    await app.applyAllFilesSelection(for: id)
                                }
                            },
                            onCancel: { Task { await app.cancelMagnetSelection() } }
                        )
                    }
                }
            case .starting:
                card { StartingIndicator() }
            case .completed(let name):
                card { CompletionBadge(name: name) }
            case .idle:
                EmptyView()
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(flow.stage.isActive)
    }

    private var selectingID: TorrentID? {
        if case .selecting(let id) = flow.stage { return id }
        return nil
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: Layout.cornerL + 6, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cornerL + 6, style: .continuous)
                    .strokeBorder(.separator.opacity(0.4))
            )
            .padding(.horizontal, 60)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.96)),
                removal: .opacity
            ))
    }
}
