import SwiftUI

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

    /// Critically damped — the default. No overshoot except where
    /// `gestureSpring` and `pop` say so.
    /// Response defaults to `standard` so springs sit on the same scale as
    /// durations rather than drifting into hand-typed values.
    static func spring(_ response: TimeInterval = Self.standard) -> Animation {
        .spring(response: response, dampingFraction: 1)
    }

    /// Slight bounce, reserved for physical gestures (drag releases) and for the
    /// few places where a thing should feel like it has weight — a toggle's
    /// knob, a checkbox filling, a selected tick landing, a toast arriving.
    static func gestureSpring(_ response: TimeInterval = Self.expressive) -> Animation {
        .spring(response: response, dampingFraction: 0.82)
    }

    static let easeOut = Animation.easeOut(duration: Self.standard)

    /// One full turn of the spinner.
    ///
    /// The only duration in the app allowed past `expressive`, because it is not
    /// a movement between two states — it is a loop, and the cap exists so that
    /// a *transition* doesn't start reading as a wait. A spinner that completed
    /// a revolution in 380 ms reads as panic. This was a hand-typed 0.85 sitting
    /// in `Spinner`, which is exactly how a scale stops being one.
    static let revolution: TimeInterval = 0.85

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
    // and the magnet flow's cards. They used to arrive four different ways — a
    // system sheet dropping out of the title bar, a couple of hand-rolled
    // fades, and one surface that deliberately didn't animate at all — so
    // opening two things in a row felt like using two applications.
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

    // MARK: - The vocabulary
    //
    // Colour in this app already means something — accent is happening, green
    // worked, red broke — and motion now works the same way. Five movements,
    // one meaning each, so that what moves on screen can be read like what is
    // coloured:
    //
    //   flow    — data is moving right now. A light runs along a progress bar,
    //             and stops the moment the transfer does. (`ProgressTrack`)
    //   drop    — something arrived or finished. One ripple, once. (`Ripple`)
    //   shake   — that didn't work. Two small swings. (`.shake(trigger:)`)
    //   stretch — you moved between choices. The front edge leaves first and
    //             the back catches up. (`StretchSpan`)
    //   origin  — a summoned surface grows out of whatever you clicked, and
    //             goes back into it. (`PopTransition`, `PresentationOrigin`)
    //
    // A new animation should be one of these, or have a reason it isn't. Motion
    // that means nothing in particular is decoration, and the colour policy
    // already says what this app thinks of that.

    /// How far a shake swings. Small: it is a head shake, not a tantrum, and
    /// the thing shaking is usually a 26pt glyph or a text field.
    static let shakeDistance: CGFloat = 3
    /// The whole shake, both swings and the settle.
    static let shakeDuration: TimeInterval = 0.3

    /// A ripple travels for `expressive` — it is the one moment in a transfer
    /// that is allowed to be noticed — and starts at this opacity.
    static let rippleOpacity: Double = 0.6

    /// One pass of the flowing light along a bar, at each of three speeds.
    ///
    /// Three, not a continuous mapping from the rate. Rates change on every
    /// engine tick, and a speed that changed with them would never settle.
    /// A rate sitting near a boundary will still flip between two buckets;
    /// `FlowLight` carries its position across a change of speed so that
    /// reads as the light speeding up or slowing down, never as a jump.
    static let flowPassFast: TimeInterval = 1.5
    static let flowPassMedium: TimeInterval = 2.0
    static let flowPassSlow: TimeInterval = 2.6
    /// Which bucket a transfer rate falls in, in bytes per second.
    static func flowPeriod(for rate: Double) -> TimeInterval {
        if rate >= 5_000_000 { return flowPassFast }
        if rate >= 500_000 { return flowPassMedium }
        return flowPassSlow
    }
    /// The share of each cycle the light spends travelling; the rest is a
    /// pause. A light that never rests reads as a loading shimmer — something
    /// waiting — rather than as something moving.
    static let flowTravelShare: Double = 0.62

    /// Stretch: the edge in the direction of travel.
    static let stretchLead: TimeInterval = 0.15
    /// Stretch: the edge left behind. Twice the lead, which is what makes the
    /// highlight read as a drop of water sliding rather than a box moving.
    static let stretchTrail: TimeInterval = 0.3

    /// Where a surface starts when it has somewhere to grow from. Smaller than
    /// `popScale`, because the distance now has a direction — it comes *from*
    /// the button instead of *at* you — and at 92% that direction is too
    /// small to see.
    static let popScaleFromOrigin: CGFloat = 0.86
    /// And how far it shrinks going back into the button.
    static let popExitScaleToOrigin: CGFloat = 0.92
}
