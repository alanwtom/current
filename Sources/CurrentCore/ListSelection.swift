import Foundation

/// Multi-selection rules for a list, as pure arithmetic.
///
/// This exists because the app stopped using `List(selection:)`. AppKit's list
/// gave click, ⌘-click, ⇧-click and arrow keys away for free; drawing the rows
/// ourselves means implementing them, and getting them subtly wrong is the kind
/// of thing nobody files a bug about — they just find the app annoying.
///
/// It lives in `CurrentCore` because it is exactly the sort of fiddly,
/// off-by-one-prone logic that deserves tests, and because it needs nothing from
/// the UI: an ordered list of ids and the selection state.
///
/// **Two markers, not one.** Getting this wrong is the classic bug. The *anchor*
/// is the fixed end of a range — the last row clicked without shift. The
/// *cursor* is the moving end. Hold shift and press ↓ twice and the anchor stays
/// put while the cursor walks down, so the selection grows; collapse them into a
/// single "last touched row" and the second press finds the range already
/// covering it and the selection stops growing after one step.
public enum ListSelection {

    /// What the user did.
    public enum Gesture: Sendable {
        /// A plain click. Selects just that row.
        case replace
        /// ⌘-click. Adds the row, or removes it if it was already selected.
        case toggle
        /// ⇧-click. Selects everything between the anchor and this row.
        case extend
    }

    /// The state a gesture produces.
    public struct Outcome: Equatable, Sendable {
        public var selection: Set<TorrentID>
        /// The fixed end of a range selection.
        public var anchor: TorrentID?
        /// The moving end — where the next arrow key starts from.
        public var cursor: TorrentID?

        public init(selection: Set<TorrentID>, anchor: TorrentID?, cursor: TorrentID?) {
            self.selection = selection
            self.anchor = anchor
            self.cursor = cursor
        }

        /// Both markers on the same row — the state after any plain click.
        static func pinned(_ id: TorrentID, selection: Set<TorrentID>? = nil) -> Outcome {
            Outcome(selection: selection ?? [id], anchor: id, cursor: id)
        }

        static let empty = Outcome(selection: [], anchor: nil, cursor: nil)
    }

    /// Applies a click to the selection.
    public static func click(
        _ gesture: Gesture,
        on id: TorrentID,
        order: [TorrentID],
        selection: Set<TorrentID>,
        anchor: TorrentID?,
        cursor: TorrentID? = nil
    ) -> Outcome {
        switch gesture {
        case .replace:
            return .pinned(id)

        case .toggle:
            var next = selection
            if next.contains(id) {
                next.remove(id)
            } else {
                next.insert(id)
            }
            // The clicked row takes both markers either way, so a following
            // shift-click extends from where the user's attention actually is.
            return .pinned(id, selection: next)

        case .extend:
            // No anchor yet — the first interaction with the list was a
            // shift-click. Treat it as a plain click rather than selecting
            // everything from the top, which is a startling number of rows.
            guard let anchor, let span = span(from: anchor, to: id, in: order) else {
                return .pinned(id)
            }
            // The span replaces the selection rather than adding to it, which
            // is what Finder and Mail do: shift-clicking back toward the anchor
            // should shrink the selection, not leave it stuck at its widest.
            return Outcome(selection: Set(span), anchor: anchor, cursor: id)
        }
    }

    /// Applies an arrow key.
    ///
    /// `extending` is shift being held. Without it the selection collapses to
    /// the one row moved to; with it the span from the anchor grows.
    public static func move(
        by delta: Int,
        order: [TorrentID],
        selection: Set<TorrentID>,
        anchor: TorrentID?,
        cursor: TorrentID? = nil,
        extending: Bool
    ) -> Outcome {
        guard !order.isEmpty else { return .empty }

        // Arrowing into an empty selection enters from the far end, so ↓ picks
        // the first row and ↑ picks the last.
        guard let from = focus(order: order, selection: selection, cursor: cursor),
              let index = order.firstIndex(of: from)
        else {
            return .pinned(delta > 0 ? order[0] : order[order.count - 1])
        }

        // Clamped, not wrapped. One keypress too many at the bottom should do
        // nothing rather than throw you back to the top of the library.
        let target = min(max(index + delta, 0), order.count - 1)
        let id = order[target]

        guard extending else { return .pinned(id) }
        guard let anchor, let span = span(from: anchor, to: id, in: order) else {
            return .pinned(id)
        }
        return Outcome(selection: Set(span), anchor: anchor, cursor: id)
    }

    /// Selects everything currently visible, leaving the markers at the ends so
    /// a following ⇧↑ narrows from the bottom.
    public static func all(order: [TorrentID]) -> Outcome {
        guard let first = order.first, let last = order.last else { return .empty }
        return Outcome(selection: Set(order), anchor: first, cursor: last)
    }

    /// The row an arrow key should move away from.
    ///
    /// The cursor when it is still on screen, otherwise the selected row nearest
    /// the bottom — so arrowing after the list has changed underneath you
    /// continues from the edge of what is left rather than from nowhere.
    public static func focus(
        order: [TorrentID],
        selection: Set<TorrentID>,
        cursor: TorrentID?
    ) -> TorrentID? {
        if let cursor, order.contains(cursor) { return cursor }
        return order.last(where: { selection.contains($0) })
    }

    /// Drops ids that are no longer in the list.
    ///
    /// Called whenever the visible set changes — switching section, typing in
    /// search, a torrent finishing and leaving Downloading. A selection holding
    /// rows that aren't on screen makes Pause and Remove act on things the user
    /// can't see, which is how you delete the wrong torrent.
    public static func pruned(
        selection: Set<TorrentID>,
        anchor: TorrentID?,
        cursor: TorrentID? = nil,
        order: [TorrentID]
    ) -> Outcome {
        let visible = Set(order)
        let next = selection.intersection(visible)
        return Outcome(
            selection: next,
            anchor: anchor.flatMap { next.contains($0) ? $0 : nil },
            cursor: cursor.flatMap { next.contains($0) ? $0 : nil }
        )
    }

    /// The inclusive run between two rows, in list order. `nil` if either row
    /// has left the list.
    private static func span(
        from: TorrentID,
        to: TorrentID,
        in order: [TorrentID]
    ) -> ArraySlice<TorrentID>? {
        guard let a = order.firstIndex(of: from), let b = order.firstIndex(of: to) else { return nil }
        return order[min(a, b)...max(a, b)]
    }
}
