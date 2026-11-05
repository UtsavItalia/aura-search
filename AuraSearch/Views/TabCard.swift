import SwiftUI

/// One tab in the home screen carousel: title above, page preview below.
///
/// Swipe up to close (like the iOS app switcher), pull down to pin or
/// unpin, tap to open. Horizontal drags are left to the carousel.
struct TabCard: View {
    let tab: BrowserTab
    let tint: Color
    /// The page snapshot, shown sharp on normal tabs.
    let snapshot: UIImage?
    /// The tiny blurred version, for private tabs, whose pages stay hidden.
    let blurredPreview: UIImage?
    /// Set by the deck: cards behind the front one are darker, the title
    /// shows only on the front card, and icons deep in the stack fade out.
    var dim: Double = 0
    var titleOpacity: Double = 1
    var iconOpacity: Double = 1
    /// How much of the header shows before the next card covers it, in the
    /// card's own points. The title fades out there instead of running
    /// under the next card's icon. `nil` for the last card.
    var headerVisibleWidth: CGFloat?
    /// Hidden while the live page is moving into (or out of) this card,
    /// since the page itself is drawn there.
    var previewHidden = false
    /// How far above its place the card is, for the copy that flies away
    /// when the card is swiped up. Real cards only move with a finger.
    var lift: CGFloat = 0
    let onOpen: () -> Void
    /// Called the moment a swipe up commits, with how far up the card was
    /// dragged and how fast it was going (points per second, negative is
    /// up), so the deck can send it flying from there at that speed.
    let onClose: (_ dragOffset: CGFloat, _ velocity: CGFloat) -> Void
    let onTogglePin: () -> Void

    /// Live drag, locked to one axis once it starts. Springs back on release.
    @GestureState(resetTransaction: Transaction(animation: Motion.standard))
    private var drag = CardDrag()
    /// The start of the swipe, kept for when it ends: by then SwiftUI may
    /// already have reset `drag`.
    @State private var swipeStart: SwipeStart?
    @State private var pinFeedback = 0

    /// How far up a card must go to close, and how far down to pin.
    private static let closeDistance: CGFloat = 130
    private static let pinDistance: CGFloat = 90
    /// The width of the fade at the end of a title the next card covers.
    private static let titleFade: CGFloat = 22
    /// Private cards are frosted, as in Arc: just the page's colors under a
    /// dark veil, with a faint sheen and a hairline edge, so a glance at your
    /// phone doesn't show what's in a private tab.
    private static let veil = Color(white: 0.26)
    private static let veilOpacity = 0.6

    struct CardDrag {
        var axis: Axis?
        /// How far the finger had gone up or down when the swipe was
        /// recognised. The card follows from there, so it doesn't jump by
        /// the threshold on the swipe's first frame.
        var slop: CGFloat = 0
        var dy: CGFloat = 0
    }

    /// Keyed by where the touch began, so a cancelled swipe can't leave a
    /// stale value for the next one.
    struct SwipeStart {
        let location: CGPoint
        let slop: CGFloat
        let isVertical: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeckLayout.headerSpacing) {
            header
            previewCard
                .opacity(previewHidden ? 0 : 1)
        }
        .overlay(alignment: .top) { pinHint }
        .offset(y: offsetY)
        .scaleEffect(cardScale)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .simultaneousGesture(dragGesture)
        .sensoryFeedback(.selection, trigger: pinFeedback)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Swipe up to close, pull down to pin")
        .accessibilityAction(named: Text("Close tab")) { onClose(0, 0) }
        .accessibilityAction(named: Text(tab.isPinned ? "Unpin tab" : "Pin tab")) { onTogglePin() }
    }

    // MARK: - Parts

    /// Like Arc's: the site icon on a small white disc and the title in
    /// small type, sitting just above the card and in from its edge.
    /// The title shows only on the front card; icons always show.
    private var header: some View {
        HStack(spacing: 8) {
            FaviconView(tab: tab, tint: tint, style: .badge)
                .opacity(iconOpacity)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(tab.displayTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tint)
                            .accessibilityLabel("Pinned")
                    }
                }
                if tab.isPrivate {
                    Text("Private Tab")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(titleOpacity)
            Spacer(minLength: 0)
        }
        .frame(height: DeckLayout.headerHeight, alignment: .bottom)
        .padding(.leading, 17.5)
        .padding(.trailing, 8)
        // Masked rather than narrowed: the text keeps its layout while the
        // deck moves, so nothing is measured again on every frame.
        .mask(alignment: .leading) { headerMask }
    }

    @ViewBuilder
    private var headerMask: some View {
        if let width = headerVisibleWidth {
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: max(width - Self.titleFade, 0))
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.titleFade)
                Spacer(minLength: 0)
            }
        } else {
            Rectangle()
        }
    }

    private var previewCard: some View {
        let shape = RoundedRectangle(cornerRadius: DeckLayout.cornerRadius, style: .continuous)
        return Group {
            if tab.isPrivate {
                frostedPreview
            } else {
                pagePreview
            }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                tab.isPinned ? tint.opacity(0.75) : Color.primary.opacity(0.08),
                lineWidth: tab.isPinned ? 2 : 0.5
            )
        )
        // A soft shadow on the leading edge, since cards stack left to right.
        // Cast by a plain shape behind the card, which never changes, so it
        // isn't drawn again on every frame while the deck moves.
        .background(
            shape
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.18), radius: 16, x: -6, y: 6)
        )
        // Cards stacked behind the front one darken, as in Arc. On top of
        // everything else, so changing it doesn't touch the shadow, and
        // always there, so the deck's layers stay the same while it moves.
        .overlay {
            shape.fill(Color.black.opacity(dim))
                .allowsHitTesting(false)
        }
    }

    /// The page as you left it, top aligned like a screenshot.
    private var pagePreview: some View {
        Color(.secondarySystemBackground)
            .overlay(alignment: .top) {
                if let snapshot {
                    // Width-fitted from the top. Pages run the card's full
                    // height; before iOS 26 they stop at the bar, a bit short.
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFit()
                } else {
                    FaviconView(tab: tab, tint: tint)
                        .scaleEffect(1.8)
                        .frame(maxHeight: .infinity)
                }
            }
    }

    // The veil color sets the card's size; the image sits in an overlay, so
    // one larger than the card can't stretch the layout.
    private var frostedPreview: some View {
        Self.veil
            .overlay {
                if let blurredPreview {
                    Image(uiImage: blurredPreview)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        // Smooths the upscaled pixels into one continuous wash.
                        .blur(radius: 8, opaque: true)
                        .saturation(1.3)
                    Self.veil.opacity(Self.veilOpacity)
                } else {
                    FaviconView(tab: tab, tint: tint)
                        .scaleEffect(1.8)
                        .opacity(0.9)
                }
            }
            .overlay {
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var pinHint: some View {
        if drag.axis == .vertical, drag.dy > 24 {
            let ready = drag.dy > Self.pinDistance
            Label(
                ready ? (tab.isPinned ? "Release to unpin" : "Release to pin")
                      : (tab.isPinned ? "Pull to unpin" : "Pull to pin"),
                systemImage: tab.isPinned ? "pin.slash.fill" : "pin.fill"
            )
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .foregroundStyle(ready ? tint : Color.secondary)
            .offset(y: -40)
            .transition(.opacity)
        }
    }

    // MARK: - Drag

    private var offsetY: CGFloat {
        let dragged: CGFloat
        if drag.axis == .vertical {
            // Up follows the finger; down resists, since it's a pull, not a move.
            dragged = drag.dy < 0 ? drag.dy : min(drag.dy * 0.45, 70)
        } else {
            dragged = 0
        }
        return dragged + lift
    }

    /// Shrinks a little as it goes up, like an app swiped away. It stays
    /// solid: a card that fades shows through the cards sliding in under it.
    private var cardScale: CGFloat {
        1 - min(max(-offsetY, 0) / 2500, 0.08)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($drag) { value, state, _ in
                if state.axis == nil {
                    state.axis = Self.isVertical(value) ? .vertical : .horizontal
                    state.slop = value.translation.height
                }
                if state.axis == .vertical {
                    state.dy = value.translation.height - state.slop
                }
            }
            .onChanged { value in
                // The same first moment `updating` saw, so the two agree.
                if swipeStart?.location != value.startLocation {
                    swipeStart = SwipeStart(
                        location: value.startLocation,
                        slop: value.translation.height,
                        isVertical: Self.isVertical(value)
                    )
                }
            }
            .onEnded { value in
                guard let start = swipeStart, start.location == value.startLocation else { return }
                swipeStart = nil
                // Only a swipe the card followed, judged by where it's drawn:
                // the flying copy starts exactly there.
                guard start.isVertical else { return }
                let dy = value.translation.height - start.slop
                let flungUp = value.predictedEndTranslation.height - start.slop < -Self.closeDistance * 2.5
                if dy < -Self.closeDistance || (dy < -30 && flungUp) {
                    onClose(dy, value.velocity.height)
                } else if dy > Self.pinDistance {
                    pinFeedback += 1
                    onTogglePin()
                }
            }
    }

    /// The axis a swipe locks onto, decided once at its first moment.
    nonisolated private static func isVertical(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.height) > abs(value.translation.width)
    }
}
