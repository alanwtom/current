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
        } else if !controller.activeDownloads.isEmpty {
            // Gate on the same list the card renders, so the panel can never be
            // sized for rows that then decline to appear.
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
        if !controller.activeDownloads.isEmpty {
            ActivityStackCard(
                torrents: controller.visibleDownloads,
                hiddenCount: controller.hiddenDownloadCount,
                isExpanded: controller.isDetailExpanded,
                onToggleMore: {
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                        controller.isDetailExpanded.toggle()
                    }
                },
                onPause: { controller.onPause($0) },
                onReveal: { controller.onReveal($0) }
            )
        }
    }
}

// MARK: - Shared stage views

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
            VStack(alignment: .leading, spacing: 1) {
                Text("Download complete")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                // The name is the point of this badge — what finished. It used
                // to be the dim subtitle under a heading that said nothing.
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download complete: \(name)")
    }
}

/// The hover card: the transfers you're actually waiting on.
///
/// Two rows by default, more on request. The panel used to open at one fixed
/// height regardless of content, so a single item — or a "download complete"
/// badge — floated in a mostly-empty black rectangle. The controller now sizes
/// the panel from `rowHeight` and the row count, so these two have to agree:
/// if you change a row's height, change `NotchWindowController.rowHeight` too.
struct ActivityStackCard: View {
    let torrents: [NotchWindowController.FeaturedTorrent]
    let hiddenCount: Int
    let isExpanded: Bool
    var onToggleMore: () -> Void
    var onPause: (TorrentID) -> Void
    var onReveal: (TorrentID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(torrents, id: \.id) { torrent in
                ActivityRow(
                    torrent: torrent,
                    onPause: { onPause(torrent.id) },
                    onReveal: { onReveal(torrent.id) }
                )
            }

            if hiddenCount > 0 {
                Button(action: onToggleMore) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                        Text(isExpanded ? "Show less" : "\(hiddenCount) more")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: NotchWindowController.moreRowHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Show fewer downloads" : "Show \(hiddenCount) more downloads")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ActivityRow: View {
    let torrent: NotchWindowController.FeaturedTorrent
    var onPause: () -> Void
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(torrent.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.95))

                ProgressTrack(fraction: torrent.progress, tint: Color.accentColor)
                    .frame(height: 3)

                HStack(spacing: 8) {
                    Text(ByteFormatting.rate(torrent.downloadRate))
                    if let eta = torrent.etaSeconds {
                        Text("\(ByteFormatting.eta(eta)) left")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2.tabularNumerics())
                .foregroundStyle(.white.opacity(0.6))
            }

            iconButton("pause.fill", label: "Pause", action: onPause)
            iconButton("folder", label: "Reveal in Finder", action: onReveal)
        }
        .frame(height: NotchWindowController.rowHeight)
        .accessibilityElement(children: .contain)
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Layout.cornerS, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
