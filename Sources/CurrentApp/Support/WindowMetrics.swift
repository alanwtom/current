import SwiftUI

/// Tracks whether the window has been shrunk past the point where the roomy
/// layout still works, and flips the app into a compact presentation.
///
/// Two things make this safe to drive from layout:
///
/// 1. It measures the **window's** content width, taken outside the split view.
///    Hiding the sidebar does not change that number. Measuring inside the
///    split view instead would feed the decision back into itself — hide the
///    sidebar, the content gets wider, the width crosses back, show it again —
///    and the window would oscillate.
/// 2. It only publishes when the boolean actually flips, so dragging a window
///    edge is not a stream of view invalidations. Per-pixel churn driving
///    window layout is what has crashed this app before.
@MainActor
final class WindowMetrics: ObservableObject {

    @Published private(set) var isCompact = false

    /// The decision itself is `WindowLayout.isCompact` — pure, and swept across
    /// window widths by `WindowLayoutTests` rather than checked once at one
    /// size. This class is only the part that has to be observable.
    func update(width: CGFloat) {
        let next = WindowLayout.isCompact(width: width, wasCompact: isCompact)
        guard next != isCompact else { return }
        isCompact = next
    }
}

extension EnvironmentValues {
    /// Read by rows so they can tighten up without every one of them needing
    /// its own observation of the window.
    @Entry var isCompactLayout: Bool = false
}
