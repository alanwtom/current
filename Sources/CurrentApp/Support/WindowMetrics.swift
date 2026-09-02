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

    /// Below this the sidebar plus a comfortable list no longer fit.
    private static let enterCompactWidth: CGFloat = 620

    /// Leaving compact deliberately needs more room than entering it. Without
    /// that gap, a window parked exactly on the threshold flickers between the
    /// two layouts as it is dragged.
    private static let leaveCompactWidth: CGFloat = 690

    @Published private(set) var isCompact = false

    func update(width: CGFloat) {
        guard width > 0 else { return }
        if isCompact, width >= Self.leaveCompactWidth {
            isCompact = false
        } else if !isCompact, width < Self.enterCompactWidth {
            isCompact = true
        }
    }
}

extension EnvironmentValues {
    /// Read by rows so they can tighten up without every one of them needing
    /// its own observation of the window.
    @Entry var isCompactLayout: Bool = false
}
