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

            if tabs.isEmpty {
                emptyState(space: space)
            } else {
                TabCarousel(tabs: tabs, tint: tint, initialPosition: initialPosition(in: tabs))
                    // A fresh deck per Space, so it starts on the right card.
                    .id(space.id)
            }

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
                withAnimation(.snappy) { session.closeUnpinnedTabs(in: space.id) }
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
            withAnimation(.snappy) { store.selectSpace(space.id) }
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
    /// `u = i − position`. Follows the finger, springs to resting positions.
    @State private var position: CGFloat
    @State private var drag = DeckDrag()
    /// Cards swiped away, still flying off the top. They're copies that
    /// ignore touches, so the next card can be swiped while they fly.
    @State private var flyingCards: [FlyingCard] = []
    @State private var closeCount = 0

    private struct FlyingCard: Identifiable {
        let id = UUID()
        let tab: BrowserTab
        let snapshot: UIImage?
        let blurredPreview: UIImage?
        let x: CGFloat
        var y: CGFloat
        let scale: CGFloat
        let dim: Double
        var opacity: Double
    }

    private struct DeckDrag {
        var start: CGPoint?
        var startPosition: CGFloat = 0
        var isHorizontal: Bool?
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

        ZStack(alignment: .topLeading) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let u = CGFloat(index) - position
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

                    TabCard(
                        tab: tab,
                        tint: tint,
                        snapshot: tab.isPrivate ? nil : session.snapshots.images[tab.id],
                        blurredPreview: tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : nil,
                        dim: DeckLayout.dim(u),
                        titleOpacity: DeckLayout.titleOpacity(u) * headerFade,
                        iconOpacity: DeckLayout.iconOpacity(u) * headerFade,
                        previewHidden: isMoving,
                        onOpen: { open(tab, at: u) },
                        onClose: { dragOffset in fling(tab, at: u, dragOffset: dragOffset) },
                        onTogglePin: { withAnimation(.snappy) { store.togglePin(tab.id) } }
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
                    onOpen: {},
                    onClose: { _ in },
                    onTogglePin: {}
                )
                .frame(width: size.width, height: totalHeight)
                .scaleEffect(card.scale, anchor: anchor)
                .opacity(card.opacity)
                .offset(x: card.x, y: card.y)
                .zIndex(100_000)
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
        .allowsHitTesting(transition == nil)
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
        .sensoryFeedback(.impact(weight: .medium), trigger: closeCount)
        .onChange(of: tabs.count) { _, count in
            // After a close, settle on the nearest place the deck can rest.
            settle(at: DeckLayout.nearestRest(to: position, from: position, count: count, maxSteps: count))
        }
    }

    // MARK: - Opening

    private func open(_ tab: BrowserTab, at u: CGFloat) {
        session.open(tab.id, fromCard: DeckLayout.previewRect(u: u, in: metrics), deckPosition: position)
    }

    /// Back to the tab you were last on (leaving a tab stamps it as the
    /// latest), as when you tap outside the cards in Arc.
    private func openMostRecent() {
        guard let recent = tabs.max(by: { $0.lastActiveAt < $1.lastActiveAt }),
              let index = tabs.firstIndex(where: { $0.id == recent.id }) else { return }
        open(recent, at: CGFloat(index) - position)
    }

    // MARK: - Closing

    /// Closes the tab the moment the swipe commits, so the next card slides
    /// into place straight away and can be swiped at once, while a copy of
    /// this one carries on flying up from where the finger let go.
    private func fling(_ tab: BrowserTab, at u: CGFloat, dragOffset: CGFloat) {
        let m = metrics
        let size = DeckLayout.cardSize(in: m)
        let totalHeight = size.height + DeckLayout.headerHeight + DeckLayout.headerSpacing
        let card = FlyingCard(
            tab: tab,
            // Taken before closing, which drops the tab's snapshots.
            snapshot: tab.isPrivate ? nil : session.snapshots.images[tab.id],
            blurredPreview: tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : nil,
            x: DeckLayout.x(u) * m.width,
            y: DeckLayout.cardTop(in: m) - DeckLayout.headerHeight - DeckLayout.headerSpacing + dragOffset,
            scale: DeckLayout.scale(u),
            dim: DeckLayout.dim(u),
            opacity: 1 - min(Double(max(-dragOffset, 0)) / 600, 0.5)
        )
        flyingCards.append(card)
        closeCount += 1
        withAnimation(.snappy(duration: 0.28)) {
            session.closeTab(tab.id)
        }
        let id = card.id
        // Next frame, once the copy is drawn where the card was.
        Task {
            withAnimation(.easeIn(duration: 0.22)) {
                if let index = flyingCards.firstIndex(where: { $0.id == id }) {
                    flyingCards[index].y = -(totalHeight + 160)
                    flyingCards[index].opacity = 0
                }
            } completion: {
                flyingCards.removeAll { $0.id == id }
            }
        }
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
                    drag.isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                guard drag.isHorizontal == true else { return }
                position = rubberBanded(drag.startPosition - value.translation.width / dragStep)
            }
            .onEnded { value in
                defer { drag = DeckDrag() }
                guard drag.isHorizontal == true else { return }
                // Where a flick would carry the deck, at most two cards away.
                let projected = drag.startPosition - value.predictedEndTranslation.width / dragStep
                settle(at: DeckLayout.nearestRest(to: projected, from: drag.startPosition, count: tabs.count))
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

    private func settle(at target: CGFloat) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            position = target
        }
    }

    @ViewBuilder
    private func menu(for tab: BrowserTab) -> some View {
        Button(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin") {
            withAnimation(.snappy) { store.togglePin(tab.id) }
        }
        let otherSpaces = store.spaces.filter { $0.id != tab.spaceID }
        if !otherSpaces.isEmpty {
            Menu {
                ForEach(otherSpaces) { space in
                    Button(space.name) {
                        withAnimation(.snappy) { store.moveTab(tab.id, to: space.id) }
                    }
                }
            } label: {
                Label("Move to Space", systemImage: "arrow.right.square")
            }
        }
        Divider()
        Button("Close Tab", systemImage: "xmark", role: .destructive) {
            withAnimation(.snappy) { session.closeTab(tab.id) }
        }
    }
}
