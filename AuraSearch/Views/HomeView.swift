import SwiftUI

/// The home screen: Spaces along the top, the Space's tabs as a deck of
/// cards, and Archive, New Tab and Settings floating at the bottom, laid
/// out in screen coordinates so the deck matches Arc point for point.
struct HomeView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.screenMetrics) private var metrics

    @State private var sheet: HomeSheet?
    @State private var confirmingCloseAll = false
    @State private var confirmingDeleteSpace = false

    private enum HomeSheet: Identifiable {
        case settings
        case archive
        case newSpace
        case editSpace(Space)

        var id: String {
            switch self {
            case .settings: return "settings"
            case .archive: return "archive"
            case .newSpace: return "newSpace"
            case .editSpace(let space): return "edit-\(space.id)"
            }
        }
    }

    /// The bars fade in as a page shrinks into the deck, and out as a card
    /// grows into its page.
    private var chromeOpacity: Double {
        session.transition.map { Double($0.progress) } ?? 1
    }

    var body: some View {
        let space = store.selectedSpace
        let tabs = store.tabs(in: space.id)
        let tint = space.color.color

        ZStack(alignment: .topLeading) {
            PastelBackground(tint: tint)

            ZStack {
                if tabs.isEmpty {
                    emptyState(space: space)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: tabs.isEmpty)

            // Kept with no tabs left too, so the last card swiped away
            // still flies off the top.
            TabCarousel(tabs: tabs, tint: tint, initialPosition: initialPosition(in: tabs))
                // A fresh deck per Space, so it starts on the right card.
                .id(space.id)

            spaceBar(space: space, tabs: tabs)
                .padding(.top, metrics.safeTop)
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(chromeOpacity)

            bottomBar
                .frame(width: metrics.width, height: BarMetrics.tapSize)
                .position(x: metrics.width / 2, y: metrics.barCenterY)
                .opacity(chromeOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        // Nothing here takes a tap while a page is moving in or out.
        .allowsHitTesting(session.transition == nil)
        .tint(tint)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .settings: SettingsView()
                case .archive: ArchiveView()
                case .newSpace: SpaceEditorView(space: nil)
                case .editSpace(let space): SpaceEditorView(space: space)
                }
            }
            .environment(store)
            .environment(session)
        }
        .confirmationDialog(
            "Close unpinned tabs in \(space.name)?",
            isPresented: $confirmingCloseAll,
            titleVisibility: .visible
        ) {
            Button("Close Tabs", role: .destructive) {
                withAnimation(Motion.reflow) { session.closeUnpinnedTabs(in: space.id) }
            }
        } message: {
            Text("They'll stay in the archive, so you can restore them.")
        }
        .confirmationDialog(
            "Delete \(space.name)?",
            isPresented: $confirmingDeleteSpace,
            titleVisibility: .visible
        ) {
            Button("Delete Space", role: .destructive) {
                session.deleteSpace(space.id)
            }
        } message: {
            Text("Its tabs move to the archive.")
        }
    }

    /// Where the deck starts: where the page is landing, or else arranged
    /// around the tab you were last on.
    private func initialPosition(in tabs: [BrowserTab]) -> CGFloat {
        if let transition = session.transition,
           transition.direction == .toDeck,
           tabs.contains(where: { $0.id == transition.tabID }) {
            return transition.deckPosition
        }
        guard let recent = tabs.max(by: { $0.lastActiveAt < $1.lastActiveAt }),
              let index = tabs.firstIndex(where: { $0.id == recent.id }) else {
            return DeckLayout.edgeShift
        }
        return DeckLayout.openingPosition(currentIndex: index, count: tabs.count)
    }

    // MARK: - Space bar

    private func spaceBar(space: Space, tabs: [BrowserTab]) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.spaces) { space in
                        spaceChip(space)
                    }
                    Button {
                        sheet = .newSpace
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Space")
                }
                .padding(.leading)
                .padding(.vertical, 8)
            }

            Menu {
                Button("Edit Space", systemImage: "pencil") { sheet = .editSpace(space) }
                Button("Close Unpinned Tabs", systemImage: "xmark.square") { confirmingCloseAll = true }
                    .disabled(!tabs.contains { !$0.isPinned })
                if store.spaces.count > 1 {
                    Divider()
                    Button("Delete Space", systemImage: "trash", role: .destructive) {
                        confirmingDeleteSpace = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing)
            .accessibilityLabel("Space options")
        }
    }

    private func spaceChip(_ space: Space) -> some View {
        let isSelected = space.id == store.selectedSpaceID
        let count = store.tabs(in: space.id).count
        return Button {
            withAnimation(Motion.quick) { store.selectSpace(space.id) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(space.color.color)
                    .frame(width: 8, height: 8)
                Text(space.name)
                    .font(.subheadline.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? AnyShapeStyle(space.color.color.opacity(0.22)) : AnyShapeStyle(.thinMaterial),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? space.color.color.opacity(0.55) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Space", systemImage: "pencil") { sheet = .editSpace(space) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Empty state

    private func emptyState(space: Space) -> some View {
        ContentUnavailableView {
            Label("No tabs in \(space.name)", systemImage: "square.on.square.dashed")
        } description: {
            Text("Tap + to search or enter an address.")
        }
        .frame(width: metrics.width, height: metrics.height)
    }

    // MARK: - Bottom bar

    /// No strip: the buttons float on the pastel, like Arc's tab screen.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            BarCircleButton(systemImage: "archivebox", label: "Archive") { sheet = .archive }
            Spacer(minLength: 0)
            BarPlusButton { session.presentSearch() }
            Spacer(minLength: 0)
            BarCircleButton(systemImage: "gearshape", label: "Settings") { sheet = .settings }
        }
        .padding(.horizontal, BarMetrics.sideInset)
    }
}

/// The Space's tabs as a deck, like the iOS app switcher and Arc Search:
/// the front card rests near the left, the next card overlaps it from the
/// right, and earlier cards stack up as darkened slivers along the left edge.
///
/// Built by hand rather than on a scroll view, so every card's position,
/// size and shading comes straight from `DeckLayout`.
private struct TabCarousel: View {
    let tabs: [BrowserTab]
    let tint: Color

    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.screenMetrics) private var metrics

    /// The deck's place as a continuous value: card `i` sits at
    /// `u = i − position` (plus any slide still left after a close).
    /// Follows the finger, then glides to a resting position on `glide`,
    /// a frame at a time.
    @State private var position: CGFloat
    @State private var drag = DeckDrag()
    @State private var glide = DeckGlide()
    /// Cards sliding over into the place of one that closed, and the clock
    /// that moves them along.
    @State private var reflow = DeckReflow()
    @State private var reflowTicker = FrameTicker()
    /// Cards swiped away, still flying off the top. They're copies that
    /// ignore touches, so the next card can be swiped while they fly.
    @State private var flyingCards: [FlyingCard] = []
    @State private var closeCount = 0

    /// A swiped-away card as it was the moment the finger let go.
    private struct FlyingCard: Identifiable {
        let id = UUID()
        let tab: BrowserTab
        let snapshot: UIImage?
        let blurredPreview: UIImage?
        let x: CGFloat
        let scale: CGFloat
        let dim: Double
        let titleOpacity: Double
        let iconOpacity: Double
        let headerVisibleWidth: CGFloat?
        /// Just under the card that came after it, as the card itself was,
        /// so letting go doesn't pop it up over its neighbor.
        let zIndex: Double
        var lift: CGFloat
    }

    private struct DeckDrag {
        var start: CGPoint?
        var startPosition: CGFloat = 0
        var isHorizontal: Bool?
        /// How far the finger had gone when the drag was recognised. The
        /// deck follows from there, so it doesn't jump by the threshold.
        var slop: CGFloat = 0
    }

    init(tabs: [BrowserTab], tint: Color, initialPosition: CGFloat) {
        self.tabs = tabs
        self.tint = tint
        _position = State(initialValue: initialPosition)
    }

    var body: some View {
        let m = metrics
        let size = DeckLayout.cardSize(in: m)
        let totalHeight = size.height + DeckLayout.headerHeight + DeckLayout.headerSpacing
        let anchor = DeckLayout.scaleAnchor(in: m)
        let cardY = DeckLayout.cardTop(in: m) - DeckLayout.headerHeight - DeckLayout.headerSpacing
        let transition = session.transition
        // Coming from a page, the other cards fly out of the tabs button.
        let entrance: CGFloat = transition?.direction == .toDeck ? 1 - (transition?.progress ?? 1) : 0
        let launch = DeckLayout.tabsButtonCenter(in: m)
        let launchDY = launch.y - (DeckLayout.cardTop(in: m) + size.height / 2)
        // Where each card is in the deck: its place, less how far the deck
        // has moved, plus however far it still has to slide after a close.
        let places = tabs.indices.map { CGFloat($0) - position + reflow.offset(for: tabs[$0].id) }

        ZStack(alignment: .topLeading) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let u = places[index]
                if DeckLayout.isVisible(u) {
                    let isMoving = transition?.tabID == tab.id
                    let e = isMoving ? 0 : entrance
                    let restScale = DeckLayout.scale(u)
                    let launchScale = restScale * 0.12
                    let restX = DeckLayout.x(u) * m.width
                    let launchX = launch.x - size.width * launchScale / 2
                    // The moving card's header fades in as the page lands
                    // (or out as it leaves).
                    let headerFade = isMoving ? Double(transition?.progress ?? 1) : 1
                    let headerWidth = headerVisibleWidth(
                        nextCardAt: places.indices.contains(index + 1) ? places[index + 1] : nil,
                        restX: restX,
                        scale: restScale
                    )
                    let titleOpacity = DeckLayout.titleOpacity(u) * headerFade
                    let iconOpacity = DeckLayout.iconOpacity(u) * headerFade

                    TabCard(
                        tab: tab,
                        tint: tint,
                        snapshot: tab.isPrivate ? nil : session.snapshots.images[tab.id],
                        blurredPreview: tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : nil,
                        dim: DeckLayout.dim(u),
                        titleOpacity: titleOpacity,
                        iconOpacity: iconOpacity,
                        headerVisibleWidth: headerWidth,
                        previewHidden: isMoving,
                        onOpen: { open(tab, at: u) },
                        onClose: { dragOffset, velocity in
                            fling(
                                tab,
                                at: u,
                                dragOffset: dragOffset,
                                velocity: velocity,
                                titleOpacity: titleOpacity,
                                iconOpacity: iconOpacity,
                                headerWidth: headerWidth
                            )
                        },
                        onTogglePin: { withAnimation(Motion.quick) { store.togglePin(tab.id) } }
                    )
                    .frame(width: size.width, height: totalHeight)
                    .scaleEffect(restScale + (launchScale - restScale) * e, anchor: anchor)
                    .opacity(DeckLayout.opacity(u) * (1 - 0.6 * Double(e)))
                    .offset(x: restX + (launchX - restX) * e, y: cardY + launchDY * e)
                    // Later cards sit on top of earlier ones.
                    .zIndex(Double(index))
                    // A closed card leaves at once; its flying copy is drawn instead.
                    .transition(.identity)
                    .contextMenu { menu(for: tab) }
                    .task(id: tab.id) {
                        if tab.isPrivate {
                            await session.snapshots.loadCardPreviewIfNeeded(tab.id)
                        } else {
                            await session.snapshots.loadIfNeeded(tab.id)
                        }
                    }
                }
            }

            ForEach(flyingCards) { card in
                TabCard(
                    tab: card.tab,
                    tint: tint,
                    snapshot: card.snapshot,
                    blurredPreview: card.blurredPreview,
                    dim: card.dim,
                    titleOpacity: card.titleOpacity,
                    iconOpacity: card.iconOpacity,
                    headerVisibleWidth: card.headerVisibleWidth,
                    lift: card.lift,
                    onOpen: {},
                    onClose: { _, _ in },
                    onTogglePin: {}
                )
                .frame(width: size.width, height: totalHeight)
                .scaleEffect(card.scale, anchor: anchor)
                .offset(x: card.x, y: cardY)
                .zIndex(card.zIndex)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Cards handle their own taps; this catches the space around them.
        .onTapGesture { openMostRecent() }
        // Simultaneous, so a card's own swipe up/down still works; each
        // gesture acts only on the direction it locked onto.
        .simultaneousGesture(deckGesture)
        .allowsHitTesting(transition == nil && !tabs.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Back to last tab")) { openMostRecent() }
        .accessibilityAdjustableAction { direction in
            let rests = DeckLayout.restPositions(count: tabs.count)
            let current = rests.indices.min { abs(rests[$0] - position) < abs(rests[$1] - position) } ?? 0
            switch direction {
            case .increment: settle(at: rests[min(current + 1, rests.count - 1)])
            case .decrement: settle(at: rests[max(current - 1, 0)])
            @unknown default: break
            }
        }
        .accessibilityHidden(tabs.isEmpty)
        .sensoryFeedback(.impact(weight: .medium), trigger: closeCount)
        .onChange(of: tabs.count) { _, count in
            // After a close, settle on the nearest place the deck can rest,
            // carrying on at the speed it's gliding, if it is.
            let target = DeckLayout.nearestRest(to: position, from: position, count: count, maxSteps: count)
            settle(at: target, velocity: glide.velocity)
        }
        .onDisappear {
            glide.stop()
            reflowTicker.stop()
        }
    }

    /// How much of a card's header shows before the next card (at
    /// `nextCardAt` in the deck, if there is one) covers it, in the card's
    /// own unscaled points, less a little breathing room.
    private func headerVisibleWidth(nextCardAt nextU: CGFloat?, restX: CGFloat, scale: CGFloat) -> CGFloat? {
        guard let nextU else { return nil }
        let nextX = DeckLayout.x(nextU) * metrics.width
        return max((nextX - restX) / max(scale, 0.01) - 6, 0)
    }

    // MARK: - Opening

    private func open(_ tab: BrowserTab, at u: CGFloat) {
        // The deck holds still while the card grows into its page.
        glide.stop()
        session.open(tab.id, fromCard: DeckLayout.previewRect(u: u, in: metrics), deckPosition: position)
    }

    /// Back to the tab you were last on (leaving a tab stamps it as the
    /// latest), as when you tap outside the cards in Arc.
    private func openMostRecent() {
        guard let recent = tabs.max(by: { $0.lastActiveAt < $1.lastActiveAt }),
              let index = tabs.firstIndex(where: { $0.id == recent.id }) else { return }
        open(recent, at: CGFloat(index) - position + reflow.offset(for: recent.id))
    }

    // MARK: - Closing

    /// Like swiping an app away: the card carries on up and off the screen
    /// at the speed the finger let go with, solid all the way, while the
    /// cards after it slide over to close the gap underneath.
    ///
    /// The tab closes the moment the swipe commits, so the next card can be
    /// swiped at once; what flies away is a copy, drawn exactly as the card
    /// was when the finger let go.
    private func fling(
        _ tab: BrowserTab,
        at u: CGFloat,
        dragOffset: CGFloat,
        velocity: CGFloat,
        titleOpacity: Double,
        iconOpacity: Double,
        headerWidth: CGFloat?
    ) {
        let m = metrics
        let size = DeckLayout.cardSize(in: m)
        let totalHeight = size.height + DeckLayout.headerHeight + DeckLayout.headerSpacing
        let cardY = DeckLayout.cardTop(in: m) - DeckLayout.headerHeight - DeckLayout.headerSpacing
        let index = tabs.firstIndex(where: { $0.id == tab.id }) ?? tabs.count
        let card = FlyingCard(
            tab: tab,
            // Taken before closing, which drops the tab's snapshots.
            snapshot: tab.isPrivate ? nil : session.snapshots.images[tab.id],
            blurredPreview: tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : nil,
            x: DeckLayout.x(u) * m.width,
            scale: DeckLayout.scale(u),
            dim: DeckLayout.dim(u),
            titleOpacity: titleOpacity,
            iconOpacity: iconOpacity,
            headerVisibleWidth: headerWidth,
            // The cards after it take its place (and number) as it closes.
            zIndex: Double(index) - 0.5,
            lift: dragOffset
        )
        flyingCards.append(card)
        closeCount += 1
        remove(tab) {
            session.closeTab(tab.id)
        }

        // Clear of the top of the screen, shadow and all.
        let target = -(cardY + totalHeight + 80)
        let speed = Motion.relativeVelocity(velocity, toCover: target - dragOffset)
        let id = card.id
        // Next frame, once the copy is drawn where the card was.
        Task {
            withAnimation(Motion.fling(velocity: speed)) {
                if let index = flyingCards.firstIndex(where: { $0.id == id }) {
                    flyingCards[index].lift = target
                }
            } completion: {
                flyingCards.removeAll { $0.id == id }
            }
        }
    }

    /// Takes `tab` out of the deck (`removal` does that) while the cards
    /// after it slide over into its place, a frame at a time. Not animated
    /// by SwiftUI: each card starts out exactly where it is, so nothing
    /// moves until the slide does.
    private func remove(_ tab: BrowserTab, by removal: () -> Void) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            reflow.remove(at: index, of: tabs.map(\.id), now: CACurrentMediaTime())
            if reflow.isMoving {
                reflowTicker.run { time in reflow.advance(to: time) }
            }
        }
        removal()
    }

    // MARK: - Dragging

    /// How far a finger travels to move the deck by one card.
    private var dragStep: CGFloat {
        max(metrics.width * 0.55, 1)
    }

    private var deckGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // A new touch (or one after a cancelled drag) starts fresh.
                if drag.start != value.startLocation {
                    drag = DeckDrag(start: value.startLocation, startPosition: position, isHorizontal: nil)
                }
                if drag.isHorizontal == nil {
                    let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                    drag.isHorizontal = isHorizontal
                    drag.slop = value.translation.width
                    // A sideways drag catches the deck wherever it is, even
                    // mid-glide. A card being swiped up or down leaves the
                    // glide to finish, so the deck still comes to rest.
                    if isHorizontal { glide.stop() }
                }
                guard drag.isHorizontal == true else { return }
                position = rubberBanded(drag.startPosition - (value.translation.width - drag.slop) / dragStep)
            }
            .onEnded { value in
                defer { drag = DeckDrag() }
                guard drag.isHorizontal == true else { return }
                // Where a flick would carry the deck, at most two cards away.
                let projected = drag.startPosition - (value.predictedEndTranslation.width - drag.slop) / dragStep
                let target = DeckLayout.nearestRest(to: projected, from: drag.startPosition, count: tabs.count)
                // The finger's speed in cards per second, so the glide
                // carries straight on from the flick.
                settle(at: target, velocity: -value.velocity.width / dragStep)
            }
    }

    /// Past the first or last card, the deck moves at a third of the speed.
    private func rubberBanded(_ value: CGFloat) -> CGFloat {
        let rests = DeckLayout.restPositions(count: tabs.count)
        let lower = rests.first ?? 0
        let upper = rests.last ?? 0
        if value < lower { return lower - (lower - value) / 3 }
        if value > upper { return upper + (value - upper) / 3 }
        return value
    }

    /// Glides the deck to `target`, starting at `velocity` cards per second.
    private func settle(at target: CGFloat, velocity: CGFloat = 0) {
        glide.start(from: position, velocity: velocity, to: target) { value in
            position = value
        }
    }

    @ViewBuilder
    private func menu(for tab: BrowserTab) -> some View {
        Button(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin") {
            withAnimation(Motion.quick) { store.togglePin(tab.id) }
        }
        let otherSpaces = store.spaces.filter { $0.id != tab.spaceID }
        if !otherSpaces.isEmpty {
            Menu {
                ForEach(otherSpaces) { space in
                    Button(space.name) {
                        remove(tab) { store.moveTab(tab.id, to: space.id) }
                    }
                }
            } label: {
                Label("Move to Space", systemImage: "arrow.right.square")
            }
        }
        Divider()
        Button("Close Tab", systemImage: "xmark", role: .destructive) {
            remove(tab) { session.closeTab(tab.id) }
        }
    }
}

/// The deck gliding to rest after a flick, worked out frame by frame.
///
/// SwiftUI's own animations jump the stored value to the end at once, so a
/// finger landing mid-glide would grab the deck where it was going rather
/// than where it is. Here the value is always what's on screen: touch the
/// deck while it glides and it stops right there, like a scroll view.
@MainActor
private final class DeckGlide {
    private let ticker = FrameTicker()
    /// How fast the deck is gliding (cards per second); 0 at rest.
    private(set) var velocity: CGFloat = 0

    /// Glides from `value` to `target`, setting off at `velocity` (cards
    /// per second), and calls `onUpdate` with the value for every frame.
    func start(from value: CGFloat, velocity: CGFloat, to target: CGFloat, onUpdate: @escaping (CGFloat) -> Void) {
        stop()
        let offset = value - target
        let velocity = velocity.isFinite ? min(max(velocity, -40), 40) : 0
        guard !Motion.FrameSpring.isSettled(offset: offset, velocity: velocity) else {
            onUpdate(target)
            return
        }
        let spring = Motion.FrameSpring.glide
        let startTime = CACurrentMediaTime()
        self.velocity = velocity
        ticker.run { [weak self] time in
            // Where the spring is at the moment this frame reaches the screen.
            let now = spring.state(offset: offset, velocity: velocity, after: CGFloat(time - startTime))
            if Motion.FrameSpring.isSettled(offset: now.offset, velocity: now.velocity) {
                self?.velocity = 0
                onUpdate(target)
                return false
            }
            self?.velocity = now.velocity
            onUpdate(target + now.offset)
            return true
        }
    }

    func stop() {
        ticker.stop()
        velocity = 0
    }
}

/// Cards sliding over into the place a closed card left, worked out frame
/// by frame like the glide. Each card starts out where it was and slides to
/// its new place, so one caught mid-slide (swiped away straight after the
/// card before it) is exactly where it looks, not where it's headed.
private struct DeckReflow {
    /// How far a card is from its place, in places (positive is to the
    /// right), and how fast it's moving, as of `start`.
    private struct Slide {
        var offset: CGFloat
        var velocity: CGFloat
        var start: CFTimeInterval

        func state(at time: CFTimeInterval) -> (offset: CGFloat, velocity: CGFloat) {
            Motion.FrameSpring.reflow.state(offset: offset, velocity: velocity, after: CGFloat(time - start))
        }
    }

    private var slides: [UUID: Slide] = [:]
    /// The moment being drawn.
    private var now: CFTimeInterval = 0

    var isMoving: Bool { !slides.isEmpty }

    /// How many places right of its own the card for `id` is drawn.
    func offset(for id: UUID) -> CGFloat {
        slides[id]?.state(at: now).offset ?? 0
    }

    /// The card at `index` in `ids` is leaving: every card after it moves
    /// up a place, setting off from where it is now (mid-slide, even).
    mutating func remove(at index: Int, of ids: [UUID], now time: CFTimeInterval) {
        guard ids.indices.contains(index) else { return }
        // While cards are moving, `now` is the frame on its way to the
        // screen, a moment ahead; start from that, so nothing skips.
        let start = max(now, time)
        slides[ids[index]] = nil
        for id in ids[(index + 1)...] {
            let current = slides[id]?.state(at: start) ?? (offset: 0, velocity: 0)
            slides[id] = Slide(offset: current.offset + 1, velocity: current.velocity, start: start)
        }
        now = start
    }

    /// Moves the clock on to `time`. False once every card is in place.
    mutating func advance(to time: CFTimeInterval) -> Bool {
        now = time
        slides = slides.filter { _, slide in
            let current = slide.state(at: time)
            return !Motion.FrameSpring.isSettled(offset: current.offset, velocity: current.velocity)
        }
        return isMoving
    }
}

/// Calls back on every frame the display draws, on its own clock (up to
/// 120 times a second on ProMotion iPhones), until the callback is done.
@MainActor
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var onFrame: ((CFTimeInterval) -> Bool)?
    /// Counts calls to `run`, so a callback that finishes doesn't stop the
    /// one that replaced it.
    private var generation = 0

    /// Calls `onFrame` with the moment each frame will reach the screen,
    /// for as long as it returns true. Replaces any callback running now.
    func run(_ onFrame: @escaping (CFTimeInterval) -> Bool) {
        generation += 1
        self.onFrame = onFrame
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let onFrame else {
            stop()
            return
        }
        let current = generation
        if !onFrame(link.targetTimestamp), generation == current {
            stop()
        }
    }
}
