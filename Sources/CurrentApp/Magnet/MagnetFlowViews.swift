import SwiftUI
import CurrentCore

// MARK: - Stage views

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

/// The one decision the magnet flow asks for: everything, or a subset.
struct SelectionSummaryCard: View {
    let name: String
    let fileCount: Int
    let totalBytes: Int64
    var onChooseFiles: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .typeStyle(Typo.heading)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(fileCount) files · \(ByteFormatting.bytes(totalBytes))")
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
                    Text("Download \(ByteFormatting.bytes(totalBytes))")
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

// MARK: - In-window presentation

/// Where a magnet link reports in: a card at the top of the library, in the
/// window, on every Mac.
///
/// This used to be the fallback for machines with no camera housing — the
/// notch panel was the main event. The panel is gone, and this is the whole
/// flow now: a question about what to download belongs next to the library it
/// is about, not in a surface that floats over other apps and can't be
/// reached by keyboard from the window.
///
/// Never blocks the library; dismisses cleanly.
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
                            name: metadata.displayName,
                            fileCount: metadata.files.count,
                            totalBytes: metadata.totalSize,
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
