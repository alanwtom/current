import SwiftUI
import AppKit

/// Light, dark, or whatever the Mac is doing.
///
/// `system` is the default and the first thing a fresh install gets: the app
/// should look like it belongs on the machine before it looks like it has an
/// opinion. The override exists because plenty of people run their Mac in light
/// mode and still want a dark app — and because this interface was designed
/// dark-first, so being able to pin it is worth having.
enum AppearanceMode: String, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Follows your Mac's appearance setting."
        case .light: return "Always light, whatever the Mac is set to."
        case .dark: return "Always dark, whatever the Mac is set to."
        }
    }

    /// `nil` hands the decision back to macOS, which then keeps the app in sync
    /// on its own — no observation needed on our side.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Pushes the chosen appearance onto the application.
///
/// Setting it on `NSApp` rather than on each window is what makes the whole
/// thing work: every window, panel, menu, the notch surface and the status item
/// inherit it, and — because the palette's colours are dynamic `NSColor`s —
/// every token in the app re-resolves without a single view knowing a change
/// happened. SwiftUI's `.preferredColorScheme` would only reach the view tree
/// and would leave the window frame, the traffic lights and the notch panel
/// wearing the system appearance.
@MainActor
enum AppearanceApplier {
    static func apply(_ mode: AppearanceMode) {
        let app = NSApplication.shared
        app.appearance = mode.nsAppearance
        // Windows created before the change keep a per-window override and a
        // cached shadow. Clearing both makes each one re-inherit from the app,
        // which is otherwise visible as a window whose frame stays dark after
        // switching to light.
        for window in app.windows {
            window.appearance = nil
            window.invalidateShadow()
        }
    }
}
