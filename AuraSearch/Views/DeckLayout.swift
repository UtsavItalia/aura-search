import SwiftUI

/// The screen's size and safe areas, measured once at the root. The deck,
/// the browser and the zoom between them all work in these screen
/// coordinates, so a page and its card line up exactly.
struct ScreenMetrics: Equatable {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0

    var isValid: Bool { width > 0 && height > safeTop }

    /// A page: from under the status bar to the bottom of the screen. The
    /// bottom bar sits over its last stretch, as in Arc, which is also why
    /// a card shows the page right down to the bottom.
    var pageRect: CGRect {
        CGRect(x: 0, y: safeTop, width: width, height: max(height - safeTop, 0))
    }

    /// Vertical centre of the bottom bar's buttons: a little into the home
    /// indicator area, where Arc puts them.
    var barCenterY: CGFloat {
        height - max(safeBottom + 10.5, 30)
    }

    /// The bottom bar covers the page from here down.
    var barTop: CGFloat {
        barCenterY - BarMetrics.height / 2 - 12.5
    }

    var barHeight: CGFloat { max(height - barTop, 0) }
}

private struct ScreenMetricsKey: EnvironmentKey {
    static let defaultValue = ScreenMetrics()
}

extension EnvironmentValues {
    var screenMetrics: ScreenMetrics {
        get { self[ScreenMetricsKey.self] }
        set { self[ScreenMetricsKey.self] = newValue }
    }
}

/// Sizes of the bottom bar's controls, matched to Arc's.
enum BarMetrics {
    /// The "+" capsule.
    static let height: CGFloat = 40
    static let capsuleWidth: CGFloat = 76
    /// The round buttons at either end.
    static let circle: CGFloat = 34
    /// Tap area around them, bigger than they look.
    static let tapSize: CGFloat = 44
    /// Puts the round buttons' centres 41pt in from the screen edges.
    static let sideInset: CGFloat = 41 - tapSize / 2
}

/// Where each card in the tab deck sits, measured frame by frame from Arc
/// Search on the same phone and kept as fractions of the screen, so it
/// carries over to other sizes.
///
/// Everything is keyed by `u`, a card's place relative to the deck's
/// position: 0 is the front card, −1 the one behind it, and 1 the next
/// one, which overlaps the front card from the right.
enum DeckLayout {
    /// A card is its page at 70%.
    static let cardScale: CGFloat = 0.7
    static let cornerRadius: CGFloat = 22
    /// The favicon and title row above each card.
    static let headerHeight: CGFloat = 30
    static let headerSpacing: CGFloat = 9
    /// At the first and last tab the deck rests this much further along,
    /// which slides the front card left from 20% to 15% of the width.
    static let edgeShift: CGFloat = 0.31

    /// Left edge, as a fraction of the screen width.
    private static let xStops: [(CGFloat, CGFloat)] = [
        (-3.31, -0.06), (-2.31, -0.018), (-1.31, 0.0205), (-1, 0.0289),
        (0, 0.2045), (0.69, 0.627), (1, 0.754), (2, 1.3),
    ]
    /// Cards behind shrink a little and cards ahead grow a little.
    private static let scaleStops: [(CGFloat, CGFloat)] = [
        (-3.31, 0.86), (-2.31, 0.918), (-1.31, 0.974), (-1, 0.982),
        (-0.31, 1), (0, 1), (0.69, 1.013), (1, 1.015), (2, 1.03),
    ]
    /// How much darker cards behind the front one are.
    private static let dimStops: [(CGFloat, CGFloat)] = [
        (-3.31, 0.7), (-2.31, 0.5), (-1.31, 0.29), (-1, 0.224), (-0.31, 0),
    ]
    private static let iconStops: [(CGFloat, CGFloat)] = [
        (-3.31, 0), (-2.31, 0.35), (-1.31, 0.55), (-1, 0.62), (-0.31, 1),
    ]

    // MARK: - Per card

    static func isVisible(_ u: CGFloat) -> Bool {
        u > -3.4 && u < 2.1
    }

    static func x(_ u: CGFloat) -> CGFloat {
        interpolate(u, xStops)
    }

    static func scale(_ u: CGFloat) -> CGFloat {
        interpolate(u, scaleStops)
    }

    static func dim(_ u: CGFloat) -> Double {
        Double(interpolate(u, dimStops))
    }

    static func iconOpacity(_ u: CGFloat) -> Double {
        Double(interpolate(u, iconStops))
    }

    /// The title shows on the front card only.
    static func titleOpacity(_ u: CGFloat) -> Double {
        if u > 0 { return Double(max(0, 1 - u / 0.4)) }
        if u < -edgeShift { return Double(max(0, 1 - (-edgeShift - u) / 0.4)) }
        return 1
    }

    /// The card furthest back fades out before it leaves.
    static func opacity(_ u: CGFloat) -> Double {
        u < -2.31 ? Double(max(0, 1 - (-2.31 - u))) : 1
    }

    // MARK: - Geometry

    static func cardSize(in m: ScreenMetrics) -> CGSize {
        CGSize(width: m.pageRect.width * cardScale, height: m.pageRect.height * cardScale)
    }

    /// Top of a resting card's page: the page shrunk to 70% about a point
    /// just above the middle of the screen (179pt down a 956pt screen).
    static func cardTop(in m: ScreenMetrics) -> CGFloat {
        let anchor = m.height * 0.474
        return anchor + (m.pageRect.minY - anchor) * cardScale
    }

    /// Where card `u`'s page is drawn on screen.
    static func previewRect(u: CGFloat, in m: ScreenMetrics) -> CGRect {
        let size = cardSize(in: m)
        let s = scale(u)
        let centerY = cardTop(in: m) + size.height / 2
        return CGRect(
            x: x(u) * m.width,
            y: centerY - size.height * s / 2,
            width: size.width * s,
            height: size.height * s
        )
    }

    /// A whole card (header and page) scales about this point: its leading
    /// edge, level with the middle of the page.
    static func scaleAnchor(in m: ScreenMetrics) -> UnitPoint {
        let size = cardSize(in: m)
        let total = size.height + headerHeight + headerSpacing
        guard total > 0 else { return .leading }
        return UnitPoint(x: 0, y: (headerHeight + headerSpacing + size.height / 2) / total)
    }

    /// The tabs button under a page, where cards fly out from.
    static func tabsButtonCenter(in m: ScreenMetrics) -> CGPoint {
        CGPoint(x: BarMetrics.sideInset + BarMetrics.tapSize / 2, y: m.barCenterY)
    }

    // MARK: - Resting positions

    /// Where the deck rests with card `index` in front.
    static func restPosition(for index: Int, count: Int) -> CGFloat {
        let isEdge = index <= 0 || index >= count - 1
        return CGFloat(index) + (isEdge ? edgeShift : 0)
    }

    static func restPositions(count: Int) -> [CGFloat] {
        (0..<max(count, 1)).map { restPosition(for: $0, count: count) }
    }

    /// The deck as it opens from a page: like the iOS app switcher, the
    /// tab you were on peeks in from the right and the one before it is in
    /// front, one tap away.
    static func openingPosition(currentIndex: Int, count: Int) -> CGFloat {
        restPosition(for: max(currentIndex - 1, 0), count: count)
    }

    /// The resting position nearest `position`, at most `maxSteps` cards
    /// from where the drag started.
    static func nearestRest(to position: CGFloat, from start: CGFloat, count: Int, maxSteps: Int = 2) -> CGFloat {
        let rests = restPositions(count: count)
        let startIndex = rests.indices.min { abs(rests[$0] - start) < abs(rests[$1] - start) } ?? 0
        let lower = max(startIndex - maxSteps, 0)
        let upper = min(startIndex + maxSteps, rests.count - 1)
        return rests[lower...upper].min { abs($0 - position) < abs($1 - position) } ?? rests[0]
    }

    /// Straight-line blend between the two stops around `value`.
    private static func interpolate(_ value: CGFloat, _ stops: [(CGFloat, CGFloat)]) -> CGFloat {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.0 {
            let t = (value - lower.0) / (upper.0 - lower.0)
            return lower.1 + (upper.1 - lower.1) * t
        }
        return last.1
    }
}
