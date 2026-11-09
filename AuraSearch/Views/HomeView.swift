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
    /// A card is held up with its menu: the deck then sits above the bars,
    /// so the dim covers the whole screen.
    @State private var isHolding = false

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
            TabCarousel(
                tabs: tabs,
                tint: tint,
                initialPosition: initialPosition(in: tabs),
                isHolding: $isHolding
            )
                // A fresh deck per Space, so it starts on the right card.
                .id(space.id)
                .zIndex(isHolding ? 1 : 0)

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
    /// The card being held up with its menu, if any.
    @State private var held: HeldCard?
    /// Drives the hold's look: the card lifted, the dim and the menu shown.
    @State private var holdShown = false
    /// The held card is leaving the deck (closed or moved to another
    /// Space), so it doesn't settle back into place.
    @State private var heldLeaving = false
    /// Closed from the menu: its flying copy is drawn instead.
    @State private var heldCopyHidden = false
    @State private var holdMenuPage = HoldMenu.Page.main
    @State private var holdCount = 0
    @Binding var isHolding: Bool

    /// How much a held card grows as it lifts.
    private static let holdLift: CGFloat = 1.04

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
        /// Grown about the page's middle, for a card closed from its menu
        /// while lifted.
        var liftScale: CGFloat = 1
    }

    private struct DeckDrag {
        var start: CGPoint?
        var startPosition: CGFloat = 0
        var isHorizontal: Bool?
        /// How far the finger had gone when the drag was recognised. The
        /// deck follows from there, so it doesn't jump by the threshold.
        var slop: CGFloat = 0
    }

    init(tabs: [BrowserTab], tint: Color, initialPosition: CGFloat, isHolding: Binding<Bool>) {
        self.tabs = tabs
        self.tint = tint
        _position = State(initialValue: initialPosition)
        _isHolding = isHolding
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
                            guard heldTabID == nil else { return }
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
                        onTogglePin: {
                            guard heldTabID == nil else { return }
                            withAnimation(Motion.quick) { store.togglePin(tab.id) }
                        },
                        onHold: {
                            hold(HeldCard(
                                tab: tab,
                                u: u,
                                titleOpacity: titleOpacity,
                                iconOpacity: iconOpacity,
                                headerWidth: headerWidth
                            ))
                        }
                    )
                    .frame(width: size.width, height: totalHeight)
                    .scaleEffect(restScale + (launchScale - restScale) * e, anchor: anchor)
                    // While held, its lifted copy is drawn instead.
                    .opacity(heldTabID == tab.id ? 0 : DeckLayout.opacity(u) * (1 - 0.6 * Double(e)))
                    .offset(x: restX + (launchX - restX) * e, y: cardY + launchDY * e)
                    // Later cards sit on top of earlier ones.
                    .zIndex(Double(index))
                    // A closed card leaves at once; its flying copy is drawn instead.
                    .transition(.identity)
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
                .scaleEffect(card.liftScale, anchor: Self.pageCenter(anchor))
                .scaleEffect(card.scale, anchor: anchor)
                .offset(x: card.x, y: cardY)
                .zIndex(card.zIndex)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if let held {
                holdLayer(held)
                    .zIndex(1000)
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
        .sensoryFeedback(.impact(weight: .medium), trigger: holdCount)
        .onChange(of: tabs.map(\.id)) { _, ids in
            // Its tab went some other way: nothing left to hold.
            if let heldTabID, !heldLeaving, !ids.contains(heldTabID) { endHold() }
        }
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
        headerWidth: CGFloat?,
        dim: Double? = nil,
        liftScale: CGFloat = 1
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
            dim: dim ?? DeckLayout.dim(u),
            titleOpacity: titleOpacity,
            iconOpacity: iconOpacity,
            headerVisibleWidth: headerWidth,
            // The cards after it take its place (and number) as it closes.
            // One closed from its menu was lifted above everything.
            zIndex: liftScale > 1 ? 1001 : Double(index) - 0.5,
            lift: dragOffset,
            liftScale: liftScale
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
                // The deck stays put under a held card's menu.
                guard heldTabID == nil else { return }
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

    // MARK: - Holding a card

    /// A held card as it was the moment the hold began. The deck stands
    /// still while its menu is up, so this is where it stays.
    private struct HeldCard {
        let tab: BrowserTab
        let u: CGFloat
        let titleOpacity: Double
        let iconOpacity: Double
        let headerWidth: CGFloat?
    }

    private var heldTabID: UUID? { held?.tab.id }

    /// Grows about the middle of the page rather than the deck's anchor,
    /// so a lifted card stays centred where it was.
    private static func pageCenter(_ anchor: UnitPoint) -> UnitPoint {
        UnitPoint(x: 0.5, y: anchor.y)
    }

    /// Lifts a card where it is, dims everything else and shows the card's
    /// menu under it. The deck holds still meanwhile.
    private func hold(_ card: HeldCard) {
        guard held == nil, session.transition == nil else { return }
        glide.stop()
        heldLeaving = false
        heldCopyHidden = false
        holdMenuPage = .main
        held = card
        isHolding = true
        holdCount += 1
        // Next frame, once the copy is drawn exactly over the card.
        Task {
            withAnimation(Motion.present) { holdShown = true }
        }
    }

    /// Settles the card back into place (or lets it go, if it's leaving)
    /// and takes the menu away; `then` runs once it's all gone.
    private func dismissHold(then action: (() -> Void)? = nil) {
        guard let id = heldTabID, holdShown else { return }
        withAnimation(Motion.dismiss) {
            holdShown = false
        } completion: {
            guard heldTabID == id else { return }
            endHold()
            action?()
        }
    }

    private func endHold() {
        held = nil
        holdShown = false
        heldLeaving = false
        heldCopyHidden = false
        holdMenuPage = .main
        isHolding = false
    }

    /// The card goes back first, then moves to where pinned cards go, so
    /// it's never seen jumping from its lifted place.
    private func pinFromMenu(_ card: HeldCard) {
        dismissHold {
            withAnimation(Motion.quick) { store.togglePin(card.tab.id) }
        }
    }

    /// Thrown up and away from where it's lifted, as if swiped: the same
    /// close, whichever way you choose.
    private func closeFromMenu(_ card: HeldCard) {
        // The flying copy takes over from the lifted one, drawn the same.
        heldCopyHidden = true
        heldLeaving = true
        fling(
            card.tab,
            at: card.u,
            dragOffset: 0,
            velocity: -1400,
            titleOpacity: card.titleOpacity,
            iconOpacity: card.iconOpacity,
            headerWidth: card.headerWidth,
            dim: 0,
            liftScale: Self.holdLift
        )
        dismissHold()
    }

    /// Fades out with the menu while the cards after it close the gap.
    private func moveFromMenu(_ card: HeldCard, to space: Space) {
        heldLeaving = true
        dismissHold()
        remove(card.tab) { store.moveTab(card.tab.id, to: space.id) }
    }

    /// The dim, the lifted card and its menu, over everything else.
    @ViewBuilder
    private func holdLayer(_ card: HeldCard) -> some View {
        let m = metrics
        let size = DeckLayout.cardSize(in: m)
        let totalHeight = size.height + DeckLayout.headerHeight + DeckLayout.headerSpacing
        let anchor = DeckLayout.scaleAnchor(in: m)
        let cardY = DeckLayout.cardTop(in: m) - DeckLayout.headerHeight - DeckLayout.headerSpacing
        let shown = holdShown
        let tab = card.tab
        let otherSpaces = store.spaces.filter { $0.id != tab.spaceID }

        // Under the lifted page, or above it if there's no room below.
        let page = DeckLayout.previewRect(u: card.u, in: m)
        let menuHeight = HoldMenu.height(page: holdMenuPage, spaceCount: otherSpaces.count)
        let floor = m.barCenterY - BarMetrics.tapSize / 2 - 12
        let below = page.midY + page.height * Self.holdLift / 2 + 12
        let menuY = min(below, floor - menuHeight)
        let menuX = min(max(page.minX, 16), m.width - HoldMenu.width - 16)

        ZStack(alignment: .topLeading) {
            Color.black
                .opacity(shown ? 0.35 : 0)
                .frame(width: m.width, height: m.height)
                .contentShape(Rectangle())
                .onTapGesture { dismissHold() }
                .accessibilityLabel("Close menu")
                .accessibilityAddTraits(.isButton)

            if !heldCopyHidden {
                TabCard(
                    tab: tab,
                    tint: tint,
                    snapshot: tab.isPrivate ? nil : session.snapshots.images[tab.id],
                    blurredPreview: tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : nil,
                    // Lifted, it's in front of everything: no shade.
                    dim: shown ? 0 : DeckLayout.dim(card.u),
                    titleOpacity: card.titleOpacity,
                    iconOpacity: card.iconOpacity,
                    headerVisibleWidth: card.headerWidth,
                    onOpen: {},
                    onClose: { _, _ in },
                    onTogglePin: {}
                )
                .frame(width: size.width, height: totalHeight)
                .scaleEffect(shown ? Self.holdLift : 1, anchor: Self.pageCenter(anchor))
                .scaleEffect(DeckLayout.scale(card.u), anchor: anchor)
                .opacity(heldLeaving && !shown ? 0 : 1)
                .offset(x: DeckLayout.x(card.u) * m.width, y: cardY)
                // A tap on it closes the menu, like a tap anywhere else.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            HoldMenu(
                tab: tab,
                otherSpaces: otherSpaces,
                page: holdMenuPage,
                onPin: { pinFromMenu(card) },
                onShowSpaces: { withAnimation(Motion.quick) { holdMenuPage = .spaces } },
                onBack: { withAnimation(Motion.quick) { holdMenuPage = .main } },
                onMove: { space in moveFromMenu(card, to: space) },
                onClose: { closeFromMenu(card) }
            )
            .scaleEffect(shown ? 1 : 0.85, anchor: .top)
            .opacity(shown ? 1 : 0)
            .offset(x: menuX, y: menuY)
            .allowsHitTesting(shown)
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
        .accessibilityAction(.escape) { dismissHold() }
    }
}

/// A held card's menu: Pin, Move to Space and Close Tab, styled like the
/// app rather than iOS's context menu. Move to Space turns the menu into
/// the list of Spaces, with a row to go back.
private struct HoldMenu: View {
    enum Page { case main, spaces }

    let tab: BrowserTab
    let otherSpaces: [Space]
    let page: Page
    let onPin: () -> Void
    let onShowSpaces: () -> Void
    let onBack: () -> Void
    let onMove: (Space) -> Void
    let onClose: () -> Void

    static let width: CGFloat = 250
    static let rowHeight: CGFloat = 48

    static func height(page: Page, spaceCount: Int) -> CGFloat {
        let rows: Int
        switch page {
        case .main: rows = spaceCount > 0 ? 3 : 2
        case .spaces: rows = 1 + spaceCount
        }
        return CGFloat(rows) * rowHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 0) {
            switch page {
            case .main:
                row(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin", action: onPin)
                if !otherSpaces.isEmpty {
                    Divider()
                    row("Move to Space", systemImage: "arrow.right.square", trailing: "chevron.right", action: onShowSpaces)
                }
                Divider()
                row("Close Tab", systemImage: "xmark", isDestructive: true, action: onClose)
            case .spaces:
                row("Move to Space", systemImage: "chevron.left", isHeader: true, action: onBack)
                ForEach(otherSpaces) { space in
                    Divider()
                    Button { onMove(space) } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(space.color.color)
                                .frame(width: 10, height: 10)
                                .frame(width: 22)
                            Text(space.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .rowLayout()
                    }
                    .buttonStyle(HoldRowStyle())
                }
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        // A hairline edge, no shadow: the dim behind already sets it apart,
        // and a blurred shadow around a material is redrawn off-screen on
        // every frame it grows in, which stalled the lift's first frames.
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func row(
        _ title: String,
        systemImage: String,
        trailing: String? = nil,
        isDestructive: Bool = false,
        isHeader: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .rowLayout()
        }
        .buttonStyle(HoldRowStyle())
    }
}

private extension View {
    func rowLayout() -> some View {
        padding(.horizontal, 16)
            .frame(height: HoldMenu.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// A menu row lights up under the finger, like iOS's own menus.
private struct HoldRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
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
