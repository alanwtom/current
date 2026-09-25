import SwiftUI
import CurrentCore

/// Bottom-trailing transient surface.
///
/// Enters with a small rise and a touch of overshoot — a toast is one of the
/// few things in the app that should feel like it *arrived* — and leaves with a
/// plain fade, because something going away shouldn't perform. Hover pauses the
/// auto-dismiss timer, so a toast can't disappear out from under a cursor
/// heading for its button.
struct ToastsOverlay: View {
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.m) {
            ForEach(toasts.toasts) { presented in
                ToastCard(toast: presented.toast) {
                    toasts.dismiss(presented.id)
                }
                .onHover { hovering in
                    if hovering {
                        toasts.pauseHover(presented.id)
                    } else {
                        toasts.resumeHover(presented.id)
                    }
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity
                                .combined(with: .move(edge: .bottom))
                                .combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)),
                            removal: .opacity
                        )
                )
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Bouncy, unlike almost everything else here: a toast is a physical
        // object sliding into a corner, and the app's motion rules allow
        // overshoot for exactly that.
        .animation(Motion.gestureSpring(Motion.standard, reduceMotion: reduceMotion), value: toasts.toasts)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }
}

private struct ToastCard: View {
    let toast: Toast
    var dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// The toast's own copy of its countdown, for the fuse: when it last
    /// started counting, and how much had run before the cursor stopped it.
    @State private var countingSince = Date()
    @State private var spentBeforeHover: TimeInterval = 0

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
                if let message = toast.message {
                    Text(message)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle = toast.actionTitle, let action = toast.action {
                    Button(actionTitle) {
                        action()
                        dismiss()
                    }
                    .currentButton(.secondary, scale: .small)
                    .padding(.top, Space.m)
                }
            }

            Spacer(minLength: 0)

            // Appears on hover only. A permanent × on every toast is four extra
            // pixels of clutter in the corner of the window at all times, and
            // the toast dismisses itself anyway.
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .iconButton(size: 18, glyph: 9)
            .opacity(isHovering ? 1 : 0)
            .help("Dismiss")
        }
        .padding(Space.l)
        .frame(width: 320, alignment: .leading)
        .raisedSurface(radius: Radius.l)
        .overlay(alignment: .bottom) { fuse }
        .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
        .onHover { hovering in
            // The same pause `ToastCenter` applies to the real timer.
            if hovering {
                spentBeforeHover += Date().timeIntervalSince(countingSince)
            } else {
                countingSince = Date()
            }
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
    }

    /// A grey line along the bottom edge that drains over the toast's life.
    ///
    /// Hovering has always held a toast open, but nothing said so, and a toast
    /// that might vanish while you read it is one you hurry. The line stops
    /// and brightens under the cursor, which is the toast saying it will wait.
    /// It shrinks by scale rather than width, and is inset by the corner
    /// radius so it runs along the straight part of the edge only.
    private var fuse: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isHovering)) { timeline in
            let spent = spentBeforeHover + (isHovering ? 0 : timeline.date.timeIntervalSince(countingSince))
            let left = max(0, 1 - spent / ToastCenter.displayDuration)
            Capsule(style: .continuous)
                .fill(isHovering ? Theme.textSecondary : Theme.textQuaternary)
                .frame(height: 2)
                .scaleEffect(x: left, anchor: .leading)
        }
        .padding(.horizontal, Radius.l)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch toast.kind {
        case .success: return Theme.complete
        case .warning: return Theme.warning
        case .info: return Theme.accent
        }
    }

    private var symbol: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}
