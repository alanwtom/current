import Foundation
import SwiftUI
import CurrentCore

struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, warning }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String?
    var actionTitle: String?
    /// Identity used to deduplicate rapid identical events.
    var coalesceKey: String?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ToastCenter: ObservableObject {
    struct PresentedToast: Identifiable, Equatable {
        let toast: Toast
        let dismissTask: Task<Void, Never>
        var id: UUID { toast.id }

        static func == (lhs: PresentedToast, rhs: PresentedToast) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var toasts: [PresentedToast] = []
    private var hoverPaused = Set<UUID>()
    private let displayDuration: TimeInterval = 5

    func show(
        _ kind: Toast.Kind,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        coalesceKey: String? = nil,
        action: (() -> Void)? = nil
    ) {
        if let key = coalesceKey,
           toasts.contains(where: { $0.toast.coalesceKey == key }) {
            return
        }
        let toast = Toast(
            kind: kind,
            title: title,
            message: message,
            actionTitle: actionTitle,
            coalesceKey: coalesceKey
        )
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.displayDuration ?? 5 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
        withAnimation(Self.animation()) {
            toasts.append(PresentedToast(toast: toast, dismissTask: task))
        }
        if toasts.count > 3 {
            dismiss(toasts[0].id)
        }
        _ = action
    }

    private static func animation(exit: Bool = false) -> Animation {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return Motion.adaptive(exit ? 0.16 : 0.26, reduceMotion: reduceMotion)
    }

    func dismiss(_ id: UUID) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        let presented = toasts[index]
        presented.dismissTask.cancel()
        withAnimation(Self.animation(exit: true)) {
            _ = toasts.remove(at: index)
        }
    }

    func pauseHover(_ id: UUID) {
        hoverPaused.insert(id)
    }

    func resumeHover(_ id: UUID) {
        hoverPaused.remove(id)
    }
}
