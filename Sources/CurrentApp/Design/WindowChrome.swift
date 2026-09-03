import SwiftUI
import AppKit

/// Strips the window down to a shell the app draws itself.
///
/// The single biggest reason the old build read as a stock Mac utility was the
/// window: a system title bar, a system unified toolbar with a search field
/// wedged into it, and a hairline the app didn't choose. All of that is gone.
/// What is left is one surface that runs to all four edges, with the three
/// window buttons floating on it.
///
/// **There is deliberately no `NSToolbar`.** An empty unified toolbar is the
/// supported way to get a taller title bar with the window buttons re-centred
/// into it, and that was the first thing tried here. It does work — but SwiftUI
/// content placed in that title bar region is no longer offered the window's
/// width, and the chrome bar silently sized itself to its leading controls,
/// dropping the search field and every button to its right off the edge. It
/// looked exactly like those views had failed to render.
///
/// So: no toolbar, no top safe area, and the SwiftUI content owns the window
/// from y=0. `ChromeBar` then lines its controls up with the window buttons by
/// hand — see `Chrome.barControlHeight`.
struct WindowChrome: NSViewRepresentable {
    /// Asked before the window closes. Return `true` to let it go; return
    /// `false` and call the supplied `proceed` action later to close it after
    /// the user has answered something.
    var shouldClose: (@escaping () -> Void) -> Bool = { _ in true }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindowChange = { [weak probe] in
            context.coordinator.attach(to: probe?.window)
        }
        probe.onLayout = { [weak probe] in
            context.coordinator.realignTrafficLights(in: probe?.window)
        }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.attach(to: probe.window)
    }

    /// Zero-sized and draws nothing; it exists only to reach the `NSWindow`.
    /// `viewDidMoveToWindow` is the earliest reliable moment — on the first pass
    /// through `makeNSView` the view has no window yet.
    final class Probe: NSView {
        var onWindowChange: (() -> Void)?
        var onLayout: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        /// Fires whenever the window re-lays out, which is when AppKit is most
        /// likely to have put the window buttons back where it wants them.
        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    @MainActor
    final class Coordinator {
        static let placedKey = "window.didApplyDefaultSize"

        var shouldClose: (@escaping () -> Void) -> Bool = { _ in true }

        private weak var window: NSWindow?
        private var hasPlaced = false
        private var closeGuard: CloseGuard?

        func attach(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            self.window = window
            configure(window)
            installCloseGuard(on: window)
            realignTrafficLights(in: window)
            placeOnFirstLaunch(window)
            // AppKit and SwiftUI both finish their own window layout after we
            // get here, and both undo what we just did — the buttons go back
            // where AppKit wants them and the frame goes back to SwiftUI's
            // guess. A few passes over the first half-second settle it; each one
            // is a no-op once things already match.
            for delay in [0.05, 0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.realignTrafficLights(in: window)
                    self?.placeOnFirstLaunch(window)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.commitPlacement()
            }
        }

        /// Lets the app answer "should this window close?".
        ///
        /// SwiftUI offers no hook for this, and it already owns the window's
        /// delegate — so rather than replacing that delegate and quietly
        /// breaking whatever it does, this one sits in front and forwards every
        /// message it doesn't handle straight through to it.
        private func installCloseGuard(on window: NSWindow) {
            guard closeGuard == nil else { return }
            let guardian = CloseGuard()
            guardian.next = window.delegate
            guardian.shouldClose = { [weak self] proceed in
                self?.shouldClose(proceed) ?? true
            }
            window.delegate = guardian
            closeGuard = guardian
        }

        /// Centres the three window buttons on the chrome bar's middle.
        ///
        /// AppKit centres them in a notional 28pt title bar, which is the wrong
        /// place once the app draws a 44pt bar of its own — the row ends up
        /// jammed against the top edge. Moving them means growing the title bar
        /// container first: the buttons still *draw* outside their superview,
        /// but they stop receiving clicks, and a window whose close button does
        /// nothing is a genuinely bad outcome. Growing the container keeps hit
        /// testing intact.
        ///
        /// Every step is optional-guarded. If AppKit ever changes this view
        /// hierarchy the worst case is buttons that sit where they always did.
        func realignTrafficLights(in window: NSWindow?) {
            guard let window,
                  !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview
            else { return }

            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }

            if abs(titlebar.frame.height - Chrome.barHeight) > 0.5 {
                if let container = titlebar.superview {
                    var frame = container.frame
                    let top = frame.maxY
                    frame.size.height = Chrome.barHeight
                    frame.origin.y = top - Chrome.barHeight
                    container.frame = frame
                }
                titlebar.frame = CGRect(
                    x: titlebar.frame.origin.x,
                    y: 0,
                    width: titlebar.frame.width,
                    height: Chrome.barHeight
                )
            }

            // Non-flipped coordinates: y counts up from the bottom of the
            // titlebar view, whose height is now the bar's height.
            let centre = Chrome.barHeight / 2
            for button in buttons {
                let target = centre - button.frame.height / 2
                guard abs(button.frame.origin.y - target) > 0.5 else { continue }
                button.frame.origin.y = target
            }
        }

        private func configure(_ window: NSWindow) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // Clear, not a colour: the blur view installed below is what the
            // window is actually made of, and an opaque background behind it
            // would simply hide it.
            // The blur itself is a SwiftUI background (`WindowBlur`); this
            // just stops AppKit painting an opaque colour underneath it.
            window.isOpaque = false
            window.backgroundColor = .clear

            // See the note at the top of the file.
            window.toolbar = nil

            // Dragging is granted deliberately, by `WindowDragRegion`, and only
            // in the chrome bar. Switching it on globally would mean a sloppy
            // click-drag on a torrent row moved the window instead of starting
            // a selection.
            window.isMovableByWindowBackground = false

            // Belt and braces only. The minimum that actually holds is stated
            // on the scene's content in `CurrentApp` — SwiftUI computes its own
            // from the view tree and installs it after this runs, so a value set
            // here alone is silently replaced. (Verified by dragging the corner:
            // with only this line, the window resized straight past it.)
            window.contentMinSize = Chrome.minimumWindowSize
        }

        /// Gives the window `Chrome.defaultWindowSize`, centred, on the very
        /// first launch and never again.
        ///
        /// Two approaches were tried and abandoned first, both of which look
        /// like they should work:
        ///
        /// - SwiftUI's `.defaultSize(width:height:)` is ignored outright here.
        ///   With no saved state at all the window still opened at a
        ///   SwiftUI-chosen 982×572, because this scene's content is fully
        ///   flexible and `defaultSize` is only a hint.
        /// - `setFrameAutosaveName` doesn't stick either. SwiftUI installs its
        ///   own autosave name afterwards and restores from that, so the entry
        ///   we register is never even written.
        ///
        /// So this doesn't fight SwiftUI's restoration; it just gets in ahead of
        /// it once. Every later launch has a remembered frame and this does
        /// nothing, which is exactly the behaviour anyone expects from a window.
        private func placeOnFirstLaunch(_ window: NSWindow) {
            guard !hasPlaced,
                  !UserDefaults.standard.bool(forKey: Self.placedKey)
            else { return }
            window.setContentSize(Chrome.defaultWindowSize)
            window.center()
        }

        /// Set only once the window has had time to settle, so a size SwiftUI
        /// applies late doesn't win and then get remembered forever.
        private func commitPlacement() {
            guard !hasPlaced else { return }
            hasPlaced = true
            UserDefaults.standard.set(true, forKey: Self.placedKey)
        }
    }
}

// MARK: - Blur

/// A blurred view of whatever is behind the window.
///
/// This is what makes the window glass instead of a grey box. It has to be a
/// SwiftUI `.background` at the very bottom of the shell, *not* an
/// `NSVisualEffectView` inserted into the window's content view by hand — the
/// first attempt did exactly that and the entire interface vanished. An AppKit
/// subview added inside SwiftUI's hosting view composites above SwiftUI's own
/// drawing regardless of `positioned: .below`, so the blur simply painted over
/// the app.
///
/// `.active` rather than `.followsWindowActiveState`: a window that loses its
/// blur the moment you click away flickers every time you switch apps, which
/// for a background utility is most of the time.
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Drag region

/// Makes a patch of the window draggable.
///
/// With the title bar gone there is nothing left to grab, so the chrome bar has
/// to take that job on. `mouseDownCanMoveWindow` is the supported way to say so,
/// and it has to be an override rather than a property — hence a whole
/// representable for one boolean.
///
/// It sits *behind* the bar's controls. AppKit gives the drag behaviour to the
/// view under the cursor, so a button on top of this keeps its own clicks and a
/// double-click on the empty space still zooms the window, exactly like a real
/// title bar.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// MARK: - Close interception

/// Sits in front of SwiftUI's own window delegate and forwards everything it
/// doesn't care about.
///
/// The forwarding is the whole trick. `NSWindowDelegate` has dozens of optional
/// methods and SwiftUI implements a number of them for its own window
/// management; simply taking the delegate over would silently disable those.
/// Overriding `responds(to:)` and `forwardingTarget(for:)` means this object
/// answers only for `windowShouldClose(_:)` and is transparent for the rest.
private final class CloseGuard: NSObject, NSWindowDelegate {
    /// Held strongly: `NSWindow.delegate` is a weak reference, so once we take
    /// the slot nothing else may be keeping SwiftUI's delegate alive.
    var next: NSWindowDelegate?
    var shouldClose: (@escaping () -> Void) -> Bool = { _ in true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let proceed: () -> Void = { [weak sender] in sender?.close() }
        guard !shouldClose(proceed) else {
            return next?.windowShouldClose?(sender) ?? true
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return next?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        next
    }
}
