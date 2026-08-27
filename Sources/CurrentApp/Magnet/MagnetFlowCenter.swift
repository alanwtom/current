import Foundation
import CurrentCore

/// State machine for the signature interaction:
/// magnet → resolving → file selection → downloading → completion.
///
/// One stage machine drives every presentation surface (notch window,
/// in-window card) so they can never disagree.
@MainActor
final class MagnetFlowCenter: ObservableObject {

    enum Stage: Equatable {
        case idle
        case resolving(nameHint: String?, startedAt: Date)
        case selecting(TorrentID)
        case starting(TorrentID)
        case completed(name: String)

        var isActive: Bool { self != .idle }
    }

    @Published var stage: Stage = .idle
    /// True while a drag session hovers the notch target.
    @Published var isDropTarget = false
    /// True when the pointer rests on the surface (notch mode only).
    @Published var isHovered = false
    /// Where the flow is being presented.
    var usesNotchSurface: Bool { notchController.isAvailable }

    private let notchController: NotchWindowController
    private var selectingID: TorrentID?

    init(notchController: NotchWindowController) {
        self.notchController = notchController
    }

    // MARK: - Transitions

    func beginResolving(nameHint: String?) {
        stage = .resolving(nameHint: nameHint, startedAt: Date())
    }

    func metadataArrived(id: TorrentID) {
        guard case .resolving = stage else { return }
        selectingID = id
        stage = .selecting(id)
    }

    func confirmSelection() {
        guard let id = selectingID else { return }
        stage = .starting(id)
    }

    func handoffFinished() {
        guard case .starting = stage else { return }
        stage = .idle
    }

    func downloadCompleted(name: String) {
        stage = .completed(name: name)
        // One short celebration, then back to quiet. Never lingers.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run { [weak self] in
                guard let self, case .completed = self.stage else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        stage = .idle
        selectingID = nil
        isDropTarget = false
    }

    func resolveFailed(message: String) {
        dismiss()
    }
}
