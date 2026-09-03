import SwiftUI
import AppKit
import CurrentCore

/// ⌘K accelerator.
///
/// **It bubbles in like every other modal surface here, and it used not to.**
/// This was the app's one deliberate exception to its own motion system — the
/// argument being that a keyboard surface reached hundreds of times a day
/// shouldn't make anyone watch it arrive. What that missed is *what* it was
/// avoiding: the old entrance was a panel easing down into place, and the thing
/// worth avoiding there was the easing, not the animating. Nothing waits on the
/// bubble. The field takes focus in `onAppear`, which fires as the transition
/// starts, so the first keystroke lands during it and the palette is already
/// filtering by the time it settles.
///
/// The highlight moves for the same reason — one shared pill that slides between
/// rows, so holding ↓ reads as travelling down a list rather than as a fill
/// blinking from row to row.
struct CommandPalette: View {
    @EnvironmentObject private var app: AppEnvironment
    @Binding var isVisible: Bool
    let commands: [Command]

    struct Command: Identifiable {
        let id = UUID()
        let title: String
        var symbol: String
        var shortcutHint: String?
        let action: () -> Void

        init(
            _ title: String,
            symbol: String = "command",
            shortcutHint: String? = nil,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.symbol = symbol
            self.shortcutHint = shortcutHint
            self.action = action
        }
    }

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowSize) private var windowSize

    /// Row geometry, shared by the rows themselves and the height calculation
    /// below — they have to agree or the list scrolls when it shouldn't.
    private static let rowHeight: CGFloat = 34
    private static let rowSpacing: CGFloat = 1
    private static let maxListHeight: CGFloat = 320
    /// The field, the footer and the two hairlines: everything in the palette
    /// that isn't the list. Used to work out what's left for the list.
    private static let chromeHeight: CGFloat = 60 + 34 + 2
    private static let topOffset: CGFloat = 110

    private var listHeight: CGFloat {
        let count = CGFloat(filtered.count)
        let content = count * Self.rowHeight
            + max(0, count - 1) * Self.rowSpacing
            + Space.s * 2
        return min(content, Self.maxListHeight)
    }

    /// Where the palette hangs from, and how much list fits underneath.
    ///
    /// Both give way in a short window, in that order — the offset above the
    /// palette is empty space and the list isn't. At 110pt down with a full
    /// 320pt list the palette needs 526pt of window; below that it used to run
    /// off the bottom, taking the ↑↓/↩/esc footer with it.
    private var fit: (top: CGFloat, listHeight: CGFloat) {
        WindowLayout.paletteLayout(
            containerHeight: windowSize.height,
            preferredTop: Self.topOffset,
            preferredListHeight: listHeight,
            chromeHeight: Self.chromeHeight,
            minimumListHeight: Self.rowHeight + Space.s * 2,
            margin: Chrome.modalMargin
        )
    }

    /// Ranked, not just filtered. A match at the start of the title, or at the
    /// start of a word inside it, beats one buried mid-word — so typing "pol"
    /// offers the seed-policy commands before anything that merely contains
    /// those letters somewhere.
    private var filtered: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands
            .compactMap { command -> (Command, Int)? in
                guard let score = Self.score(command.title, query: trimmed) else { return nil }
                return (command, score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Lower is better.
    private static func score(_ title: String, query: String) -> Int? {
        let haystack = title.lowercased()
        let needle = query.lowercased()
        guard let range = haystack.range(of: needle) else { return nil }
        let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
        if offset == 0 { return 0 }
        // A match that starts a word is nearly as good as one at the beginning.
        let previous = haystack[haystack.index(before: range.lowerBound)]
        if previous == " " || previous == "-" { return 1 }
        return 2 + offset
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.scrim
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { close() }

            VStack(spacing: 0) {
                field
                Hairline()

                if filtered.isEmpty {
                    Text("No matching command")
                        .typeStyle(Typo.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xxl)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: Self.rowSpacing) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                                    row(command: command, index: index)
                                        .id(index)
                                }
                            }
                            .padding(Space.s)
                        }
                        // Sized to the rows it actually has, capped so a long
                        // list scrolls instead of filling the window.
                        //
                        // `maxHeight` alone doesn't work: a `ScrollView` is
                        // greedy vertically, so it took the full 320pt whether
                        // there were twelve results or two, and the palette hung
                        // open as a mostly-empty rectangle. The rows are a fixed
                        // height, so the real height is just arithmetic.
                        .frame(height: fit.listHeight)
                        .scrollIndicators(.never)
                        .onChange(of: highlightedIndex) { _, index in
                            proxy.scrollTo(index, anchor: .bottom)
                        }
                    }
                }

                Hairline()
                footer
            }
            .modalSize(width: 520)
            .raisedSurface(radius: Radius.xl, deep: true)
            .popTransition(reduceMotion: reduceMotion)
            .padding(.top, fit.top)
        }
        // Measured from the top of the window rather than from the safe area,
        // so the 110pt above the palette is really 110 — see `ModalSurface`.
        .ignoresSafeArea()
        .onAppear {
            query = ""
            highlightedIndex = 0
            isFocused = true
        }
        // Clamped whenever the result set shrinks. Without it, arrowing down a
        // long list and then typing leaves the highlight past the end, and ↩
        // silently does nothing.
        .onChange(of: filtered.count) { _, count in
            highlightedIndex = min(highlightedIndex, max(0, count - 1))
        }
        .background(PaletteKeyHandler(
            onUp: { move(-1) },
            onDown: { move(1) },
            onEscape: { close() },
            onReturn: { run(highlightedIndex) }
        ))
    }

    private var field: some View {
        HStack(spacing: Space.l) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .typeStyle(Typo.display)
                .foregroundStyle(Theme.text)
                .focused($isFocused)
                .onSubmit { run(highlightedIndex) }
        }
        .padding(.horizontal, Space.xl)
        .frame(height: 60)
    }

    private var footer: some View {
        HStack(spacing: Space.l) {
            hint("↑↓", "navigate")
            hint("↩", "run")
            hint("esc", "close")
            Spacer()
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: Space.xs) {
            KeyHint(keys)
            Text(label)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textQuaternary)
        }
    }

    private func row(command: Command, index: Int) -> some View {
        let isHighlighted = index == highlightedIndex

        return Button {
            run(index)
        } label: {
            HStack(spacing: Space.l) {
                Image(systemName: command.symbol)
                    .font(.system(size: Size.iconSmall, weight: .medium))
                    .frame(width: Size.iconColumn)
                    .foregroundStyle(isHighlighted ? Theme.text : Theme.textTertiary)
                Text(command.title)
                    .typeStyle(Typo.label)
                    .foregroundStyle(isHighlighted ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Space.m)
                if let shortcut = command.shortcutHint {
                    KeyHint(shortcut)
                        .opacity(isHighlighted ? 1 : 0.6)
                }
            }
            .padding(.horizontal, Space.l)
            .frame(height: Self.rowHeight)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(Theme.fillMuted)
                        .matchedGeometryEffect(id: "palette.highlight", in: highlight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
        .accessibilityAddTraits(isHighlighted ? [.isSelected, .isButton] : .isButton)
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        withAnimation(.easeOut(duration: Motion.instant)) {
            highlightedIndex = max(0, min(filtered.count - 1, highlightedIndex + delta))
        }
    }

    private func run(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        let command = filtered[index]
        // Closed first, then run. Several commands open a sheet or a settings
        // pane, and dismissing the palette afterwards would fight whatever the
        // command had just presented.
        close()
        command.action()
    }

    private func close() {
        isVisible = false
    }
}

// MARK: - Key routing for the palette

/// Arrow keys, escape and return, routed around the text field.
///
/// A local `NSEvent` monitor rather than `keyDown` on this view or `.onKeyPress`
/// in SwiftUI: the text field holds first responder for as long as the palette
/// is open, so nothing else ever sees these keys. The monitor returns `nil` for
/// the four it handles and passes everything else straight through, so typing
/// still works normally.
private struct PaletteKeyHandler: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onEscape: () -> Void
    var onReturn: () -> Void

    final class HandlerView: NSView {
        var onUp: () -> Void = {}
        var onDown: () -> Void = {}
        var onEscape: () -> Void = {}
        var onReturn: () -> Void = {}
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil else { return event }
                switch event.keyCode {
                case 126: self.onUp(); return nil
                case 125: self.onDown(); return nil
                case 53: self.onEscape(); return nil
                case 36, 76: self.onReturn(); return nil
                default: return event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }
    }

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: HandlerView, context: Context) {
        apply(to: nsView)
    }

    /// The monitor is global to the app, so failing to tear it down would leave
    /// arrow keys swallowed after the palette closes.
    static func dismantleNSView(_ nsView: HandlerView, coordinator: ()) {
        nsView.stop()
    }

    private func apply(to view: HandlerView) {
        view.onUp = onUp
        view.onDown = onDown
        view.onEscape = onEscape
        view.onReturn = onReturn
    }
}
