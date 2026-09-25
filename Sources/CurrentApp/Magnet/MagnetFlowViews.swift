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

/// The decisions the magnet flow asks for: which files, and where they go.
///
/// Both live on one card on purpose. A download's folder is only ever an
/// interesting question next to what the download *is* — a name and a size —
/// and splitting them would mean two surfaces and two clicks for something most
/// people answer by accepting the default.
struct SelectionSummaryCard: View {
    let name: String
    let fileCount: Int
    let totalBytes: Int64
    /// Non-nil while the app is asking where downloads go. Nil hides the whole
    /// block, which is what "Remember this location" buys you.
    let destination: URL?
    @Binding var remembersDestination: Bool
    var onChooseDestination: () -> Void
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

            if let destination {
                destinationBlock(destination)
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

    private func destinationBlock(_ destination: URL) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("SAVE TO")
                .typeStyle(Typo.overline)
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: Space.m) {
                Image(systemName: "folder")
                    .font(.system(size: Size.iconSmall))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Size.iconColumn)
                // Truncated in the middle, because the end of a path is the
                // part that identifies it — "…/Movies/Archive" tells you where
                // you are and "/Users/alan/Docum…" tells you nothing.
                Text(PathFormatting.friendly(destination))
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination.path)
                Spacer(minLength: Space.m)
                Button("Change…") { onChooseDestination() }
                    .currentButton(.secondary, scale: .small)
            }

            Toggle("Remember this location", isOn: $remembersDestination)
                .currentCheckbox()
                .help("Send every download here from now on. You can turn the question back on in Settings.")
        }
    }
}

struct StartingIndicator: View {
    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
            Text("Starting download…")
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
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
            // One branch for both stages, so the summary card keeps its
            // identity when Download moves the flow on — which is what lets it
            // *fly* to its row as an ordinary animated change instead of
            // leaving by a transition. A transition is fixed at the card's last
            // render, and that render can't know whether Download or Cancel is
            // coming next; this way only Download lands, and Cancel still pops
            // the card away.
            case .selecting(let id), .starting(let id):
                if case .starting = flow.stage, landingTarget == nil {
                    // The row isn't on screen to show where it went, so the
                    // card that says so comes back.
                    card { StartingIndicator() }
                } else if let metadata = store.metadataCache[id] {
                    card {
                        SelectionSummaryCard(
                            name: metadata.displayName,
                            fileCount: metadata.files.count,
                            totalBytes: metadata.totalSize,
                            destination: app.settings.asksForDownloadLocation
                                ? app.downloadDestination
                                : nil,
                            remembersDestination: $flow.remembersDestination,
                            onChooseDestination: { app.chooseDownloadDestination() },
                            onChooseFiles: { app.showMagnetFilePicker = true },
                            onConfirm: {
                                Task {
                                    await app.applyAllFilesSelection(for: id)
                                }
                            },
                            onCancel: { Task { await app.cancelMagnetSelection() } }
                        )
                    }
                    .modifier(Landing(target: reduceMotion ? nil : landingTarget))
                }
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
        .animation(stageAnimation, value: flow.stage)
    }

    /// The bubble for every stage, except the landing. A card flying into a
    /// row mustn't overshoot it — it would sail past the row and come back —
    /// so the hand-off to `.starting` rides a critically damped spring of the
    /// same length instead.
    private var stageAnimation: Animation {
        if case .starting = flow.stage {
            return Motion.spring(Motion.popResponse, reduceMotion: reduceMotion)
        }
        return Motion.pop(presenting: flow.stage.isActive, reduceMotion: reduceMotion)
    }

    /// Where the confirmed torrent's row is, once Download has been pressed and
    /// the row is on screen. Read from `RowFrames` at render time; nothing
    /// observes it, so it costs nothing while the list scrolls.
    private var landingTarget: CGRect? {
        guard case .starting(let id) = flow.stage else { return nil }
        return RowFrames.shared.onScreen(id)
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

/// The selection card flying into its torrent's row when you press Download.
///
/// The card already belongs to a row — the magnet was added to the library
/// the moment it arrived, and has been sitting there resolving while the card
/// asked about it. Popping the card away and leaving you to find the row was
/// two unrelated events; shrinking the card into the row says where your
/// download went. "Origin" in the motion vocabulary, run backwards.
///
/// The card squashes to the row's shape as it goes, which would be ugly to
/// read — so it softens as it squashes, the bubble's arrival blur run in
/// reverse, and fades on an ease-in so it stays solid for most of the flight
/// and goes only as it reaches the row. The row then takes over: it turns from
/// paused to downloading in the same moment, and that change is the landing.
struct Landing: ViewModifier {
    /// The row, in window coordinates. Nil leaves the card where it is.
    var target: CGRect?

    func body(content: Content) -> some View {
        let landed = target != nil
        let target = target ?? .zero
        return content
            .blur(radius: landed ? Motion.popBlur : 0)
            .animation(.easeIn(duration: Motion.popResponse)) { faded in
                faded.opacity(landed ? 0 : 1)
            }
            .visualEffect { effect, proxy in
                let frame = proxy.frame(in: .global)
                guard landed, frame.width > 0, frame.height > 0 else {
                    return effect.scaleEffect(x: 1, y: 1).offset(x: 0, y: 0)
                }
                return effect
                    .scaleEffect(x: target.width / frame.width, y: target.height / frame.height)
                    .offset(x: target.midX - frame.midX, y: target.midY - frame.midY)
            }
            // Invisible over the row until the flow goes idle; clicks belong
            // to the row underneath.
            .allowsHitTesting(!landed)
    }
}
