import SwiftUI
import CurrentCore

/// Bottom-trailing transient surface. Enters with a small rise + scale,
/// exits fast with a fade; hover pauses the auto-dismiss timer.
struct ToastsOverlay: View {
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
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
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .bottom))
                            .combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)),
                        removal: .opacity
                    )
                )
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(Motion.spring(reduceMotion: reduceMotion), value: toasts.toasts)
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }
}

private struct ToastCard: View {
    let toast: Toast
    var dismiss: () -> Void

    private var tint: Color {
        switch toast.kind {
        case .success: return SemanticColor.complete
        case .warning: return SemanticColor.warning
        case .info: return Color.accentColor
        }
    }

    private var symbol: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                if let message = toast.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: dismiss)
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerL, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cornerL, style: .continuous)
                .strokeBorder(.separator.opacity(0.4))
        )
    }
}
