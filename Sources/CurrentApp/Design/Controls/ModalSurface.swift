import SwiftUI
import AppKit

/// The app's modal presentation: a scrim, a card that bubbles in, and Escape.
///
/// **This replaces `.sheet`, and that was the last piece of system chrome left
/// in the window.** Both of the app's sheets — the add-magnet card behind the
/// plus button, and the file picker — were presented by AppKit, which meant
/// they dropped out of the title bar and faded, in a rhythm belonging to a
/// different application than this one. Nothing about that animation is
/// configurable, so the surfaces had to stop being sheets.
///
/// What it buys, beyond the entrance: the card is drawn by `raisedSurface` like
/// every other floating surface here, so it has the same fill, edge, top
/// highlight and shadow as the dialogs and the palette instead of AppKit's.
///
/// **A card inside this states its size with `.modalSize`, never `.frame`.**
/// That is not a style preference: a fixed `.frame` can't be capped from out
/// here (an inner fixed frame wins over any outer maximum), so a 760×540 card
/// in a 600×420 window drew straight over the edges, clipped on all four sides
/// with its close button off screen. `.modalSize` resolves the same numbers
/// against the window first.
///
/// Two things a `.sheet` gave for free and this has to do by hand:
///
/// - **Keyboard focus.** A sheet takes first responder; an overlay doesn't. So
///   whatever is inside has to claim focus itself, or the library list keeps it
///   and the arrow keys keep moving the selection behind the scrim. Both call
///   sites focus a text field on appear (see `CurrentField(autofocus:)`).
/// - **Escape.** The focused field would eat it, so it's caught by a local
///   `NSEvent` monitor — the same arrangement the palette and the dialogs use,
///   and for the same reason.
struct ModalSurface<Content: View>: View {
    /// Clicking away is a *dismissal*, never a destructive one. The file picker
    /// turns this off, because its Cancel button throws away the torrent you
    /// just pasted and a stray click shouldn't be able to do that.
    var dismissesOnBackgroundTap = true
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The scrim fades; the card bubbles. Two transitions rather than one
            // on the whole stack, because a scrim that scales looks like the room
            // itself is moving.
            Theme.scrim
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture {
                    if dismissesOnBackgroundTap { onDismiss() }
                }

            content()
                // Clipped before the surface is drawn, not after: the fill and
                // the shadow live in a `background` behind the content, so
                // clipping last would cut the shadow off at the card's edge.
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .raisedSurface(radius: Radius.xl, deep: true)
                .popTransition(reduceMotion: reduceMotion)
        }
        // Centres on the *window*, not on the safe area.
        //
        // The window has no title bar, but SwiftUI still reserves ~33pt of safe
        // area at the top, and a stack that respects it is centred in what's
        // left — so every modal sat 16pt below the middle of the window, and a
        // 540pt settings card in a 562pt window had its bottom edge clipped
        // while its top edge had 27pt of room. Measured, not guessed: 33 plus
        // half of (562 − 33 − 540) is the 27pt the card actually showed.
        .ignoresSafeArea()
        .background(EscapeCatcher(onEscape: onDismiss).frame(width: 0, height: 0))
    }
}

extension View {
    /// Presents `content` as a modal card over this view.
    ///
    /// The `ZStack` + `.animation(_:value:)` wrapper is load-bearing and easy to
    /// leave out: `isPresented` is often set from a menu, a keyboard shortcut or
    /// an AppKit callback, none of which run inside `withAnimation`, so without
    /// an animation attached here the transition never runs and the card simply
    /// appears fully formed — the one thing a modal shouldn't do.
    func modalSurface<Content: View>(
        isPresented: Binding<Bool>,
        dismissesOnBackgroundTap: Bool = true,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(
            ModalPresenter(
                isPresented: isPresented,
                dismissesOnBackgroundTap: dismissesOnBackgroundTap,
                onDismiss: onDismiss,
                modalContent: content
            )
        )
    }
}

private struct ModalPresenter<Modal: View>: ViewModifier {
    @Binding var isPresented: Bool
    var dismissesOnBackgroundTap: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder var modalContent: () -> Modal

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    ModalSurface(
                        dismissesOnBackgroundTap: dismissesOnBackgroundTap,
                        onDismiss: dismiss,
                        content: modalContent
                    )
                }
            }
            .animation(
                Motion.pop(presenting: isPresented, reduceMotion: reduceMotion),
                value: isPresented
            )
        }
    }

    private func dismiss() {
        isPresented = false
        onDismiss?()
    }
}

// MARK: - Escape

/// Escape closes the surface.
///
/// A local `NSEvent` monitor rather than a `.keyboardShortcut(.cancelAction)`:
/// every one of these surfaces has a focused text field in it, and the field
/// absorbs the key before any button ever sees it.
///
/// Shared by `ModalSurface` and `SettingsSurface`. The monitor is global to the
/// app, so tearing it down on dismantle matters — leaving one behind would
/// swallow Escape everywhere for the rest of the session.
struct EscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: CatcherView, coordinator: ()) {
        nsView.stop()
    }

    final class CatcherView: NSView {
        var onEscape: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil, event.keyCode == 53 else { return event }
                self.onEscape()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
