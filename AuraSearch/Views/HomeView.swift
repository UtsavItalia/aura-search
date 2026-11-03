import SwiftUI

/// The home screen: Spaces along the top, the Space's tabs as a card
/// carousel, and a bottom bar with Archive, New Tab and Settings.
struct HomeView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session

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

    var body: some View {
        let space = store.selectedSpace
        let tabs = store.tabs(in: space.id)
        let tint = space.color.color

        VStack(spacing: 0) {
            spaceBar(space: space, tabs: tabs)
            if tabs.isEmpty {
                emptyState(space: space)
            } else {
                TabCarousel(
                    tabs: tabs,
                    tint: tint,
                    initialTabID: carouselStart(in: tabs),
                    onTapBackground: { returnToRecentTab(in: tabs) }
                )
                    // A fresh carousel per Space, so it starts on the right card.
                    .id(space.id)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .background {
            PastelBackground(tint: tint)
                .ignoresSafeArea()
                // Tapping anywhere outside the cards goes back to your tab.
                .onTapGesture { returnToRecentTab(in: tabs) }
        }
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

    /// Back to the tab you were most recently on in this Space: the one you
    /// just left, since leaving a tab stamps it as the latest. Like tapping
    /// outside the cards in Arc Search.
    private func returnToRecentTab(in tabs: [BrowserTab]) {
        guard let recent = tabs.max(by: { $0.lastActiveAt < $1.lastActiveAt }) else { return }
        session.activate(recent.id)
    }

    /// The card the carousel opens on: the tab you just left if it's in
    /// this Space, otherwise the newest.
    private func carouselStart(in tabs: [BrowserTab]) -> UUID? {
        if let last = store.lastViewedTabID, tabs.contains(where: { $0.id == last }) {
            return last
        }
        return tabs.last?.id
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
        .frame(maxHeight: .infinity)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            circleButton("archivebox", label: "Archive") { sheet = .archive }
            Spacer()
            Button {
                session.presentSearch()
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 104, height: 52)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tab")
            Spacer()
            circleButton("gearshape", label: "Settings") { sheet = .settings }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 6)
        // No strip: the buttons float on the pastel, like Arc's tab screen.
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The Space's tabs as a deck, like the iOS app switcher and Arc Search:
/// the current card rests near the left, the next card overlaps it from the
/// right, and earlier cards stack up as slivers along the left edge.
///
/// Built by hand rather than on a scroll view, so every card's position,
/// size and brightness comes straight from `DeckLayout` and stays exact.
private struct TabCarousel: View {
    let tabs: [BrowserTab]
    let tint: Color
    /// Tapping the empty space around the cards.
    let onTapBackground: () -> Void

    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session

    /// The current card as a continuous value: 1.5 is halfway between the
    /// second and third cards. Moves with the finger, springs to whole numbers.
    @State private var position: CGFloat
    @State private var drag = DeckDrag()

    private struct DeckDrag {
        var start: CGPoint?
        var startPosition: CGFloat = 0
        var isHorizontal: Bool?
    }

    init(tabs: [BrowserTab], tint: Color, initialTabID: UUID?, onTapBackground: @escaping () -> Void) {
        self.tabs = tabs
        self.tint = tint
        self.onTapBackground = onTapBackground
        let index = tabs.firstIndex { $0.id == initialTabID } ?? max(tabs.count - 1, 0)
        _position = State(initialValue: CGFloat(index))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Header (30) + spacing (8) above the preview.
            let headerHeight: CGFloat = 38
            // Previews keep a page's shape, and leave open space above and
            // below the deck, like Arc: at most ~80% of the height available.
            let previewAspect: CGFloat = 1.95
            let maxPreviewHeight = max((proxy.size.height - headerHeight) * 0.8, 0)
            let cardWidth = min(width * 0.68, maxPreviewHeight / previewAspect, 400)
            let cardHeight = cardWidth * previewAspect + headerHeight
            let top = (proxy.size.height - cardHeight) / 2
            // How far a finger travels to move one card.
            let dragStep = width * 0.47

            ZStack(alignment: .topLeading) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    // Where this card sits relative to the current one: 0 is
                    // current, -1 the one behind it, 1 the next.
                    let relative = CGFloat(index) - position
                    if DeckLayout.isVisible(relative) {
                        TabCard(
                            tab: tab,
                            tint: tint,
                            snapshot: tab.isPrivate ? nil : session.snapshots.images[tab.id],
                            blurredPreview: tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : nil,
                            titleOpacity: DeckLayout.titleOpacity(relative),
                            iconOpacity: DeckLayout.iconOpacity(relative),
                            onOpen: { session.activate(tab.id) },
                            onClose: { withAnimation(.snappy) { session.closeTab(tab.id) } },
                            onTogglePin: { withAnimation(.snappy) { store.togglePin(tab.id) } }
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(DeckLayout.scale(relative))
                        .brightness(DeckLayout.brightness(relative))
                        .opacity(DeckLayout.opacity(relative))
                        .offset(x: DeckLayout.x(relative) * width, y: top)
                        // Later cards sit on top of earlier ones.
                        .zIndex(Double(index))
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
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            // Cards handle their own taps; this catches the space around them.
            .onTapGesture { onTapBackground() }
            // Simultaneous, so a card's own swipe up/down still works; each
            // gesture acts only on the direction it locked onto.
            .simultaneousGesture(deckGesture(step: dragStep))
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Back to last tab")) { onTapBackground() }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: settle(at: position + 1)
                case .decrement: settle(at: position - 1)
                @unknown default: break
                }
            }
        }
        .onChange(of: tabs.count) { _, count in
            // After closing the last card, step back onto the new last one.
            if position > CGFloat(count - 1) { settle(at: CGFloat(count - 1)) }
        }
    }

    // MARK: - Dragging

    private func deckGesture(step: CGFloat) -> some Gesture {
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
                position = rubberBanded(drag.startPosition - value.translation.width / step)
            }
            .onEnded { value in
                defer { drag = DeckDrag() }
                guard drag.isHorizontal == true else { return }
                // Where a flick would carry the deck, at most two cards away.
                let projected = drag.startPosition - value.predictedEndTranslation.width / step
                let start = drag.startPosition.rounded()
                let target = min(max(projected.rounded(), start - 2), start + 2)
                settle(at: target)
            }
    }

    /// Past the first or last card, the deck moves at a third of the speed.
    private func rubberBanded(_ value: CGFloat) -> CGFloat {
        let last = CGFloat(max(tabs.count - 1, 0))
        if value < 0 { return value / 3 }
        if value > last { return last + (value - last) / 3 }
        return value
    }

    private func settle(at target: CGFloat) {
        let last = CGFloat(max(tabs.count - 1, 0))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            position = min(max(target.rounded(), 0), last)
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

/// Where each card sits, measured from Arc Search's switcher. Values are
/// keyed by a card's position relative to the current card and blended in
/// between, so cards glide smoothly from one slot to the next while dragging.
private enum DeckLayout {
    /// Leading edge as a fraction of the screen width. The current card rests
    /// at 15%, the next one overlaps its right quarter, and cards behind
    /// leave a sliver of about 13% each, then tuck off the edge.
    private static let xStops: [(CGFloat, CGFloat)] = [
        (-3, -0.06), (-2, -0.012), (-1, 0.022), (0, 0.15), (1, 0.62), (2, 1.1),
    ]
    /// Cards behind shrink a little and cards ahead grow a little, for depth.
    private static let scaleStops: [(CGFloat, CGFloat)] = [
        (-3, 0.86), (-2, 0.92), (-1, 0.97), (0, 1), (1, 1.02), (2, 1.03),
    ]

    static func isVisible(_ relative: CGFloat) -> Bool {
        relative > -3.5 && relative < 2.5
    }

    static func x(_ relative: CGFloat) -> CGFloat {
        interpolate(relative, xStops)
    }

    static func scale(_ relative: CGFloat) -> CGFloat {
        interpolate(relative, scaleStops)
    }

    /// Cards behind dim slightly, so the current card reads as the front.
    static func brightness(_ relative: CGFloat) -> Double {
        relative < 0 ? Double(max(relative * 0.04, -0.12)) : 0
    }

    /// The third card back fades out before it leaves.
    static func opacity(_ relative: CGFloat) -> Double {
        relative < -2 ? Double(max(0, 1 + (relative + 2))) : 1
    }

    /// Visible only while the card is (nearly) current.
    static func titleOpacity(_ relative: CGFloat) -> Double {
        Double(max(0, 1 - abs(relative) * 2.5))
    }

    /// Icons of cards two back are half faded, so the stack doesn't clutter.
    static func iconOpacity(_ relative: CGFloat) -> Double {
        relative >= -1 ? 1 : Double(max(0, 1 + (relative + 1) * 0.6))
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
