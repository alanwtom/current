import SwiftUI

/// Central motion + spacing tokens. Every animation in the app references
/// these so timing stays coherent and audits stay possible.
enum Motion {
    /// Press feedback, checkbox ticks. Fast enough to feel like the control itself.
    static let instant: TimeInterval = 0.12
    /// Hovers, small state changes, priority menu feedback.
    static let quick: TimeInterval = 0.18
    /// Surfaces that appear or change shape (notch expansion, inspector).
    static let standard: TimeInterval = 0.28
    /// Large surface transitions (magnet flow stages).
    static let expressive: TimeInterval = 0.38

    /// Critically damped — the default. No overshoot anywhere in the app.
    static func spring(_ response: TimeInterval = 0.3) -> Animation {
        .spring(response: response, dampingFraction: 1)
    }

    /// Slight bounce, reserved for physical gestures (drag releases).
    static func gestureSpring(_ response: TimeInterval = 0.34) -> Animation {
        .spring(response: response, dampingFraction: 0.82)
    }

    static let easeOut = Animation.easeOut(duration: Self.standard)

    /// Reduced Motion keeps feedback but drops movement distance.
    static func adaptive(_ duration: TimeInterval, reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? min(duration, 0.2) : duration)
    }

    /// Reduced Motion variant of the shared springs.
    static func spring(_ response: TimeInterval = 0.3, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: min(response, 0.2)) : Self.spring(response)
    }
}

enum Layout {
    static let rowHeight: CGFloat = 64
    static let cornerS: CGFloat = 6
    static let cornerM: CGFloat = 10
    static let cornerL: CGFloat = 16
    static let contentPadding: CGFloat = 20
}

enum SemanticColor {
    /// Active transfer — the system accent, used sparingly.
    static var downloading: Color { .accentColor }
    static var seeding: Color { .teal }
    static var complete: Color { .green }
    static var paused: Color { .secondary }
    static var failure: Color { .red }
    static var warning: Color { .orange }
}

extension View {
    /// Continuous-updating numbers (rates, sizes, ETAs) must never shift width.
    func tabularNumerics() -> some View {
        monospacedDigit()
    }
}

extension Font {
    func tabularNumerics() -> Font {
        monospacedDigit()
    }
}
