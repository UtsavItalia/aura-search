import SwiftUI

/// Every animation in the app, in one place, so it all moves the same way.
///
/// Tuned to feel like iOS itself: springs with no wobble at system speeds,
/// fades only where one thing gives way to another, and anything thrown by
/// a finger carries on at the finger's speed instead of starting from rest.
/// Use these rather than writing `.spring(...)` or `.easeOut(...)` in a view.
enum Motion {
    // MARK: - Moving into place

    /// A page shrinking into its card or growing back out of it. Timed from
    /// Arc Search, and close to iOS opening an app from the app switcher.
    static let zoom = Animation.spring(duration: 0.36, bounce: 0.1)

    /// The default for anything moving to a new place: a little quicker
    /// than SwiftUI's `.smooth`, with no overshoot.
    static let standard = Animation.spring(duration: 0.4, bounce: 0)

    /// A new page arriving: from a search, or a link that opens a tab.
    static let arrive = Animation.spring(duration: 0.45, bounce: 0)

    /// Panels coming up, like the search panel.
    static let present = Animation.spring(response: 0.36, dampingFraction: 0.9)

    /// Panels going away: about as long as the keyboard takes.
    static let dismiss = Animation.spring(duration: 0.3, bounce: 0)

    /// Cards closing the gap a closed card left, like the app switcher.
    static let reflow = Animation.spring(duration: 0.5, bounce: 0)

    /// Small things changing state: toggles, chips, a button's label.
    static let quick = Animation.spring(duration: 0.25, bounce: 0)

    // MARK: - Fading

    /// One piece of content giving way to another: a page to the next page,
    /// a loading cover to the page underneath.
    static let crossfade = Animation.easeOut(duration: 0.28)

    /// Something appearing or disappearing where it is: a label, a badge.
    static let fade = Animation.easeInOut(duration: 0.2)

    /// Something that ticks along steadily, like a progress bar.
    static let progress = Animation.linear(duration: 0.2)

    /// A placeholder gently breathing while it waits for content.
    static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    // MARK: - After a gesture

    /// Settles something that was moving under a finger, carrying on at the
    /// speed the finger let go with, so there's no jolt.
    /// - Parameter velocity: from `relativeVelocity(_:toCover:)`.
    static func settle(velocity: Double) -> Animation {
        .interpolatingSpring(duration: 0.45, bounce: 0, initialVelocity: clamped(velocity))
    }

    /// Throws something off screen at the finger's speed, like swiping an
    /// app away in the app switcher.
    static func fling(velocity: Double) -> Animation {
        .interpolatingSpring(duration: 0.42, bounce: 0, initialVelocity: clamped(velocity))
    }

    /// A finger's speed in the form springs want it: points per second as a
    /// share of the distance still to cover. Zero if there's nowhere to go.
    static func relativeVelocity(_ pointsPerSecond: CGFloat, toCover distance: CGFloat) -> Double {
        guard abs(distance) > 0.5 else { return 0 }
        return Double(pointsPerSecond / distance)
    }

    /// No backwards kick (a spring with a negative start would first move
    /// away from where it's going) and no runaway values.
    private static func clamped(_ velocity: Double) -> Double {
        guard velocity.isFinite else { return 0 }
        return min(max(velocity, 0), 30)
    }
}

// MARK: - Worked out a frame at a time

extension Motion {
    /// A spring for motion the app works out on every frame itself instead
    /// of handing to SwiftUI, as the tab deck does. SwiftUI stores an
    /// animated value's end the moment the animation starts, but the deck
    /// has to know where it really is right now: a finger can catch it
    /// mid-glide, or swipe away a card that's still sliding into place.
    ///
    /// Critically damped (the quickest way there with no overshoot), so it
    /// feels like the springs above, and solved exactly for any moment, so
    /// it moves the same at 60 or 120 frames a second.
    struct FrameSpring {
        /// How quickly it closes in, in radians per second.
        let frequency: CGFloat

        /// `response` is the spring's duration, as in
        /// `.spring(duration: response, bounce: 0)`.
        init(response: CGFloat) {
            frequency = 2 * .pi / response
        }

        /// The deck gliding to rest after a flick or a drag.
        static let glide = FrameSpring(response: 0.42)

        /// Cards sliding over into a closed card's place: the same curve as
        /// `Motion.reflow`.
        static let reflow = FrameSpring(response: 0.5)

        /// For something that started `offset` from where it's going, moving
        /// at `velocity` (per second): how far it still has to go `time`
        /// seconds later, and how fast it's moving then.
        func state(offset: CGFloat, velocity: CGFloat, after time: CGFloat) -> (offset: CGFloat, velocity: CGFloat) {
            let w = frequency
            let t = max(time, 0)
            let b = velocity + w * offset
            let decay = exp(-w * t)
            return ((offset + b * t) * decay, (velocity - w * b * t) * decay)
        }

        /// Close enough to count as there: well under a point on screen.
        static func isSettled(offset: CGFloat, velocity: CGFloat) -> Bool {
            abs(offset) < 0.0005 && abs(velocity) < 0.01
        }
    }
}
