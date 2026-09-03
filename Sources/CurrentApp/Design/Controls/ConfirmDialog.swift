import SwiftUI
import AppKit

/// The app's confirmation dialog.
///
/// Replaces `.confirmationDialog`, which draws AppKit's sheet — a system-font
/// title, system buttons and a drop-down animation that belongs to a different
/// application than this one. This is the same surface as the command palette:
/// a raised card on a scrim, with the keyboard route printed on the buttons.
///
/// **The key hints are the point.** A dialog that shows `esc` on Cancel and `↩`
/// on the confirm button teaches its own shortcuts, so the second time you see
/// it you never touch the mouse. Both keys are wired here, not just drawn.
struct ConfirmDialog: View {
    let title: String
    let message: String

    var confirmTitle: String
    var confirmIsDestructive = false
    /// A middle option, for the times there are genuinely three answers — the
    /// removal dialog's "keep the files on disk".
    var alternateTitle: String?

    var onConfirm: () -> Void
    var onAlternate: (() -> Void)?
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The scrim fades; the card bubbles. Two transitions rather than one
            // on the whole stack, because a scrim that scales looks like the
            // room itself is moving.
            Theme.scrim
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(title)
                        .typeStyle(Typo.title)
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .typeStyle(Typo.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.xxl)

                Hairline()

                HStack(spacing: Space.m) {
                    Spacer(minLength: Space.m)

                    Button(action: onCancel) {
                        DialogLabel(title: "Cancel", key: "esc")
                    }
                    .currentButton(.ghost)

                    if let alternateTitle, let onAlternate {
                        Button(action: onAlternate) {
                            DialogLabel(title: alternateTitle, key: nil)
                        }
                        .currentButton(.secondary)
                    }

                    Button(action: onConfirm) {
                        DialogLabel(title: confirmTitle, key: "↩")
                    }
                    .currentButton(confirmIsDestructive ? .destructive : .primary)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.l)
            }
            .modalSize(width: 440)
            .raisedSurface(radius: Radius.xl, deep: true)
            // The same entrance as every other modal surface here. It used to
            // have its own — a slightly different scale from a slightly
            // different direction — which is how an app ends up feeling
            // assembled from parts.
            .popTransition(reduceMotion: reduceMotion)
        }
        // Centred on the window, not on the safe area — see `ModalSurface`.
        .ignoresSafeArea()
        .background(
            DialogKeys(onEscape: onCancel, onReturn: onConfirm)
                .frame(width: 0, height: 0)
        )
    }
}

/// A button label with its keyboard equivalent printed beside it, dimmed.
private struct DialogLabel: View {
    let title: String
    let key: String?

    var body: some View {
        HStack(spacing: Space.s) {
            Text(title)
            if let key {
                Text(key)
                    .typeStyle(Typo.caption)
                    .opacity(0.5)
            }
        }
    }
}

/// Escape cancels, Return confirms.
///
/// A local `NSEvent` monitor for the same reason the command palette needs one:
/// whatever had focus when the dialog appeared still has it, so nothing in the
/// dialog's own view tree is offered these keys.
private struct DialogKeys: NSViewRepresentable {
    let onEscape: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onEscape = onEscape
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onReturn = onReturn
    }

    static func dismantleNSView(_ nsView: KeyView, coordinator: ()) {
        nsView.stop()
    }

    final class KeyView: NSView {
        var onEscape: () -> Void = {}
        var onReturn: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil else { return event }
                switch event.keyCode {
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
    }
}
