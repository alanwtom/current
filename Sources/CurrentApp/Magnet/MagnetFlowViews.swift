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
        controller.surfaceState == .hidden ? 0 : Radius.l
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
        HStack(spacing: Space.s) {
            Spinner(size: 11, tint: Theme.textSecondary)
            Text("Resolving magnet…")
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.s)
    }
}

struct ResolvingCard: View {
    let hint: String?
    let startedAt: Date
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.l) {
                Spinner(size: 13, tint: Theme.accent)
                Text(hint ?? "Resolving magnet…")
                    .typeStyle(Typo.heading)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Space.m)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .iconButton(size: 20, glyph: 9)
                .keyboardShortcut(.cancelAction)
                .help("Cancel")
            }

            // Ticks once a second only to change one sentence after fifteen
            // seconds. Cheap, and it is the difference between "this is taking
            // a while" and "this is broken".
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                Text(elapsed > 15 ? "Still looking — this can take a minute" : "Contacting peers for file details")
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Chrome.panePadding)
    }
}

struct SelectionSummaryCard: View {
    let summary: NotchWindowController.SelectionSummary
    var onChooseFiles: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .typeStyle(Typo.heading)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(summary.fileCount) files · \(ByteFormatting.bytes(summary.totalBytes))")
                        .typeStyle(Typo.caption)
                        .tabularNumerics()
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Space.m)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .iconButton(size: 20, glyph: 9)
                .keyboardShortcut(.cancelAction)
                .help("Cancel")
            }

            HStack(spacing: Space.m) {
                Button("Choose files…") { onChooseFiles() }
                    .currentButton(.secondary, scale: .small)
                Spacer(minLength: Space.m)
                Button(action: onConfirm) {
                    Text("Download \(ByteFormatting.bytes(summary.totalBytes))")
                        .tabularNumerics()
                }
                .currentButton(.primary, scale: .small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
    }
}

struct StartingIndicator: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
            Text("Starting download…")
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.s)
    }
}

struct CompletionBadge: View {
    let name: String

    var body: some View {
        HStack(spacing: Space.l) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.complete)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 1) {
                Text("Download complete")
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
                // The name is the point of this badge — what finished. It used
                // to be the dim subtitle under a heading that said nothing.
                Text(name)
                    .typeStyle(Typo.heading)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
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
                    HStack(spacing: Space.xs) {
                        // Rotates rather than swapping glyphs: one arrow that
                        // turns says "this opens and closes" better than two.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        Text(isExpanded ? "Show less" : "\(hiddenCount) more")
                            .typeStyle(Typo.caption)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchWindowController.moreRowHeight)
                    .contentShape(Rectangle())
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
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(torrent.name)
                    .typeStyle(Typo.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)

                ProgressTrack(fraction: torrent.progress, tint: Theme.downloading)
                    .frame(height: 3)

                HStack(spacing: Space.m) {
                    Text(ByteFormatting.rate(torrent.downloadRate))
                        .numericTransition()
                    if let eta = torrent.etaSeconds {
                        Text("\(ByteFormatting.eta(eta)) left")
                            .numericTransition()
                    }
                    Spacer(minLength: 0)
                }
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .foregroundStyle(Theme.textTertiary)
            }

            Button(action: onPause) { Image(systemName: "pause.fill") }
                .iconButton(size: 22, glyph: 10)
                .help("Pause")
            Button(action: onReveal) { Image(systemName: "folder") }
                .iconButton(size: 22, glyph: 10)
                .help("Reveal in Finder")
        }
        .frame(height: NotchWindowController.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Drop target content (drawn while a drag session is over the notch)

struct DropTargetBadge: View {
    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 20, weight: .light))
            Text("Drop to add")
                .typeStyle(Typo.caption)
        }
        .foregroundStyle(Theme.text)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // The stages are driven from an async task, so nothing sets them inside
        // `withAnimation` and the cards' own transitions had no animation to run
        // with — each stage simply blinked into place. Keyed on the stage rather
        // than on anything inside it: the resolving card ticks a clock every
        // second, and animating on per-tick values is what has taken this app's
        // window down before.
        .animation(
            Motion.pop(presenting: flow.stage.isActive, reduceMotion: reduceMotion),
            value: flow.stage
        )
    }

    private var selectingID: TorrentID? {
        if case .selecting(let id) = flow.stage { return id }
        return nil
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 460)
            .raisedSurface(radius: Radius.xl, deep: true)
            .popTransition(reduceMotion: reduceMotion)
            .padding(.horizontal, Space.xxxl)
    }
}
