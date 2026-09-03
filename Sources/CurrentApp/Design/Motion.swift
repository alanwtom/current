import SwiftUI
import QuartzCore

/// Central motion tokens. Every animation in the app references these so timing
/// stays coherent and audits stay possible.
///
/// Nothing exceeds ~300ms for a single movement. The reason is not dogma: this
/// app's surfaces are small and its interactions are repeated hundreds of times
/// a day, and past about a third of a second a repeated animation stops reading
/// as responsiveness and starts reading as a wait.
enum Motion {
    /// Press feedback, hover fills, checkbox ticks. Fast enough to feel like the
    /// control itself rather than a reaction to it.
    static let instant: TimeInterval = 0.12
    /// Small state changes: a chevron turning, a chip swapping colour.
    static let quick: TimeInterval = 0.18
    /// Surfaces that appear or change shape — the inspector, a popover, the
    /// sidebar folding away.
    static let standard: TimeInterval = 0.28
    /// Large surface transitions (magnet flow stages).
    static let expressive: TimeInterval = 0.38

    /// Critically damped — the default. No overshoot anywhere in the app.
    /// Response defaults to `standard` so springs sit on the same scale as
    /// durations rather than drifting into hand-typed values.
    static func spring(_ response: TimeInterval = Self.standard) -> Animation {
        .spring(response: response, dampingFraction: 1)
    }

    /// Slight bounce, reserved for physical gestures (drag releases) and for the
    /// one or two places where a thing should feel like it has weight — a
    /// toggle's knob, a toast arriving.
    static func gestureSpring(_ response: TimeInterval = Self.expressive) -> Animation {
        .spring(response: response, dampingFraction: 0.82)
    }

    static let easeOut = Animation.easeOut(duration: Self.standard)

    /// Reduced Motion keeps feedback but drops movement distance.
    static func adaptive(_ duration: TimeInterval, reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? min(duration, 0.2) : duration)
    }

    /// Reduced Motion variant of the shared springs.
    static func spring(_ response: TimeInterval = Self.standard, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: min(response, 0.2)) : Self.spring(response)
    }

    /// Reduced Motion variant of the bouncy spring. Bounce is movement, so it is
    /// the first thing to go.
    static func gestureSpring(_ response: TimeInterval = Self.expressive, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: min(response, 0.2)) : Self.gestureSpring(response)
    }

    // MARK: - The bubble
    //
    // The one entrance every modal surface in the app shares: the add-magnet
    // card, the file picker, the confirm dialogs, settings, the command palette
    // and the notch panel. They used to arrive four different ways — a system
    // sheet dropping out of the title bar, a couple of hand-rolled fades, and
    // one surface that deliberately didn't animate at all — so opening two
    // things in a row felt like using two applications.
    //
    // It bubbles: starts small, slightly soft, and springs past its final size
    // by a few percent before settling. This is the third and last place in the
    // app allowed to overshoot (the others being a toggle's knob and a toast
    // arriving), and unlike those two it isn't a physical gesture — it's here
    // because a surface that pops feels like it was summoned, which is exactly
    // what pressing ⌘K or the plus button is.

    /// Spring response for an arriving surface. Longer than `standard`, because
    /// a spring's response is the time to *reach* its target rather than to stop
    /// moving, and a bubble cut short reads as a flinch.
    static let popResponse: TimeInterval = 0.32
    /// How small a surface starts. Any smaller and it flies at you; any larger
    /// and the bounce has nothing to bounce from.
    static let popScale: CGFloat = 0.92
    /// Dismissal barely shrinks — a surface getting out of the way shouldn't
    /// perform on the way out.
    static let popExitScale: CGFloat = 0.98
    /// The gooey part. Arriving out of focus and sharpening as it lands is what
    /// separates "bubbled in" from "scaled up".
    static let popBlur: CGFloat = 6

    /// A surface arriving.
    static func pop(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeOut(duration: Self.instant)
            : .spring(response: Self.popResponse, dampingFraction: 0.66)
    }

    /// A surface leaving. Fast and flat: no bounce, no travel.
    static func popExit(reduceMotion: Bool = false) -> Animation {
        .easeOut(duration: reduceMotion ? 0.1 : Self.instant)
    }

    /// What a presenting overlay hands to `.animation(_:value:)`.
    ///
    /// Both directions have to come from one modifier, so the direction is read
    /// off the flag being animated rather than from two separate animations.
    static func pop(presenting: Bool, reduceMotion: Bool = false) -> Animation {
        presenting ? Self.pop(reduceMotion: reduceMotion) : Self.popExit(reduceMotion: reduceMotion)
    }

    /// The bubble, for the one surface that can't use a SwiftUI spring: the
    /// notch panel, whose size is an `NSWindow` frame animated through
    /// `NSAnimationContext`.
    ///
    /// A cubic Bézier can overshoot if a control point sits above 1, which is
    /// how this fakes the spring's settle. It is an approximation and it only
    /// has to match closely enough that the panel and the surfaces inside the
    /// window feel like the same app.
    static var popTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 1.28, 0.36, 1)
    }

    // MARK: - Micro-interaction constants
    //
    // The magnitudes, not just the timings. These are here for the same reason
    // the durations are: a press that shrinks 4% in one place and 1% in another
    // makes the app feel assembled from parts.

    /// How far a pressed control shrinks. Small — the point is to feel the press
    /// under the cursor, not to watch the button move.
    static let pressScale: CGFloat = 0.97
    /// A row or card, which is bigger and so needs less scale to read as pressed.
    static let pressScaleLarge: CGFloat = 0.99
    /// How far a surface travels when it slides in (palette, toast, popover).
    static let enterOffset: CGFloat = 8
    /// Per-item delay in a staggered entrance.
    static let stagger: TimeInterval = 0.028
    /// Cap on a stagger, so a list of forty rows doesn't take a second to arrive.
    static let staggerCap: Int = 8
}
