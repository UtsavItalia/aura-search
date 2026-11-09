import SwiftUI

/// A tab on screen. The page runs from under the status bar to the bottom
/// of the screen, with the bar floating over its last stretch, as in Arc.
///
/// While moving to or from the tab screen, the live page itself shrinks
/// into its card (or grows out of it): no copy, no crossfade. Growing out
/// of a card, it shows the card's picture until the zoom is over and the
/// web view is back in the window (`BrowserSession.holdBack`).
struct BrowserView: View {
    let tab: BrowserTab
    @Binding var readerArticle: ReaderArticle?

    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.screenMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingMenu = false
    /// Something to do once the page menu has finished closing, since a
    /// second sheet or the find bar can't appear while it's still up.
    @State private var afterMenuCloses: MenuFollowUp?
    @State private var readerMessage: String?

    private enum MenuFollowUp {
        case reader
        case find
        case summarize
        case downloads
    }

    private var tint: Color {
        store.space(withID: tab.spaceID)?.color.color ?? .accentColor
    }

    /// 0 while the page fills the screen, 1 once it has become its card.
    private var cardProgress: CGFloat {
        guard let transition = session.transition, transition.tabID == tab.id else { return 0 }
        return transition.progress
    }

    /// 0 as a newly opened page starts growing in (from a search, or a link
    /// that opens a tab), 1 once it's in place, and for every other page.
    private var arrivalProgress: CGFloat {
        guard let arrival = session.arrival, arrival.tabID == tab.id else { return 1 }
        return arrival.progress
    }

    var body: some View {
        let t = cardProgress
        let page = metrics.pageRect
        let card = session.transition.flatMap { $0.tabID == tab.id ? $0.cardRect : nil } ?? page
        let ratio = page.width > 0 ? card.width / page.width : 1
        let scale = 1 + (ratio - 1) * t
        let dx = (card.minX - page.minX) * t
        let dy = (card.minY - page.minY) * t
        // A new page grows in from a little smaller, with rounded corners.
        let a = arrivalProgress
        let arrivalScale = 0.94 + 0.06 * a
        // Drawn before scaling, so it lands on the card's 22pt corners.
        let cornerRadius = max(t * DeckLayout.cornerRadius / max(ratio, 0.05), (1 - a) * 32)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack(alignment: .topLeading) {
            // An arriving page comes in over the tab screen's backdrop.
            if a < 1 {
                PastelBackground(tint: tint)
                    .frame(width: metrics.width, height: metrics.height)
            }

            // Behind the status bar.
            Color(.systemBackground)
                .frame(width: metrics.width, height: page.minY)
                .opacity(Double((1 - t) * a))

            // The card's shadow, cast while the page moves.
            shape
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18 * Double(t)), radius: 16, x: -6, y: 6)
                .frame(width: page.width, height: page.height)
                .scaleEffect(arrivalScale)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: page.minX + dx, y: page.minY + dy)
                .opacity(Double(a))

            pageContent
                .frame(width: page.width, height: page.height)
                .clipShape(shape)
                .scaleEffect(arrivalScale)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: page.minX + dx, y: page.minY + dy)
                .opacity(Double(a))

            bottomBar
                .opacity(Double(1 - t))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(session.transition == nil)
        .tint(tint)
        .task(id: tab.id) {
            session.refreshNavigationState()
            // Needed for the loading snapshot when a tab reopens at launch.
            await session.snapshots.loadIfNeeded(tab.id)
        }
        .sheet(isPresented: $showingMenu, onDismiss: { runFollowUp() }) {
            PageMenuView(
                tab: tab,
                onReader: { closeMenu(then: .reader) },
                onFind: { closeMenu(then: .find) },
                onSummarize: { closeMenu(then: .summarize) },
                onDownloads: { closeMenu(then: .downloads) }
            )
            .environment(store)
            .environment(session)
        }
        .sheet(isPresented: showingSummary) {
            SummaryView(tab: tab)
                .environment(store)
                .environment(session)
        }
        .alert(
            "Reader Mode",
            isPresented: Binding(get: { readerMessage != nil }, set: { if !$0 { readerMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(readerMessage ?? "")
        }
    }

    // MARK: - Page

    private var pageContent: some View {
        WebViewContainer(
            webView: session.webView(for: tab),
            bottomInset: metrics.barHeight,
            // Out of the window while its card grows into the page; the
            // loading cover shows the card's picture meanwhile.
            isAttached: session.heldBackTabID != tab.id
        )
            .overlay { loadingCover }
            .overlay {
                // A private page turns to frosted glass as it lands in the deck.
                if tab.isPrivate {
                    Color(white: 0.26)
                        .opacity(0.85 * Double(cardProgress))
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.crossfade, value: session.paintedTabs.contains(tab.id))
    }

    /// What shows until the page has drawn, so pages never blink or flash
    /// blank: the picture of the page a link is leaving, or the tab's last
    /// snapshot (a tab reloading), or a plain sheet instead of WebKit's
    /// empty white. It appears at once and fades away once the page draws.
    @ViewBuilder
    private var loadingCover: some View {
        if !session.paintedTabs.contains(tab.id), tab.url != nil {
            // The picture and the plain background sit one above the other,
            // never overlapping. Layered, each faded on its own and halfway
            // through the page showed through both: a dip to 75% brightness,
            // seen as the page greying after every open in dark mode. (A
            // compositing group fixed that but drew the dark background white.)
            VStack(spacing: 0) {
                if let picture = session.pageCovers[tab.id] ?? session.snapshots.images[tab.id] {
                    // Width-fitted from the top, the way it was taken.
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Below a picture shorter than the page, or instead of one.
                Color(.systemBackground)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ZStack(alignment: .top) {
            barBackground

            if session.isLoading {
                Rectangle()
                    .fill(tint)
                    .frame(width: metrics.width * CGFloat(session.progress), height: 2)
                    .frame(width: metrics.width, alignment: .leading)
                    .animation(Motion.progress, value: session.progress)
            }

            HStack(spacing: 0) {
                TabStackButton(images: stackImages) { session.showHome() }
                Spacer(minLength: 0)
                BarPlusButton { session.presentSearch() }
                Spacer(minLength: 0)
                BarCircleButton(systemImage: "chevron.up", label: "Page menu") { showingMenu = true }
            }
            .padding(.horizontal, BarMetrics.sideInset)
            .frame(width: metrics.width, height: BarMetrics.tapSize)
            .offset(y: metrics.barCenterY - metrics.barTop - BarMetrics.tapSize / 2)
        }
        .frame(width: metrics.width, height: metrics.barHeight, alignment: .top)
        // Private tabs get a dark bar with light icons, as in Arc.
        .environment(\.colorScheme, tab.isPrivate ? .dark : colorScheme)
        .contentShape(Rectangle())
        // Swiping up on the bar opens the menu too.
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { showingMenu = true }
            }
        )
        .offset(y: metrics.barTop)
    }

    /// The tab screen's own backdrop, cut down to the bar, so the bar and
    /// the deck behind it read as one surface during the zoom.
    @ViewBuilder
    private var barBackground: some View {
        if tab.isPrivate {
            Color(red: 0.18, green: 0.18, blue: 0.20)
                .frame(width: metrics.width, height: metrics.barHeight)
        } else {
            PastelBackground(tint: tint)
                .frame(width: metrics.width, height: metrics.height)
                .offset(y: -metrics.barTop)
                .frame(width: metrics.width, height: metrics.barHeight, alignment: .top)
                .clipped()
        }
    }

    /// The previous tab, then this one, for the tabs button.
    private var stackImages: [UIImage] {
        let previous = store.tabs(in: tab.spaceID)
            .filter { $0.id != tab.id }
            .max { $0.lastActiveAt < $1.lastActiveAt }
        return [previous.flatMap { thumbnail(for: $0) }, thumbnail(for: tab)].compactMap { $0 }
    }

    private func thumbnail(for tab: BrowserTab) -> UIImage? {
        tab.isPrivate ? session.snapshots.cardPreviews[tab.id] : session.snapshots.images[tab.id]
    }

    // MARK: - Menu follow-ups

    private func closeMenu(then followUp: MenuFollowUp) {
        afterMenuCloses = followUp
        showingMenu = false
    }

    private func runFollowUp() {
        guard let followUp = afterMenuCloses else { return }
        afterMenuCloses = nil
        switch followUp {
        case .find:
            session.presentFindOnPage()
        case .reader:
            Task { await openReader() }
        case .summarize:
            session.requestSummary(for: tab.id)
        case .downloads:
            session.downloads.isListPresented = true
        }
    }

    /// Up while this tab's summary is open, from the menu or a pinch.
    private var showingSummary: Binding<Bool> {
        Binding(
            get: { session.summaryTabID == tab.id },
            set: { if !$0 { session.summaryTabID = nil } }
        )
    }

    private func openReader() async {
        guard ReaderMode.isAvailable else {
            readerMessage = "Reader mode isn't bundled in this build. Run scripts/bootstrap.sh to add it."
            return
        }
        if let article = await session.readerArticle() {
            readerArticle = article
        } else {
            readerMessage = "This page doesn't look like an article."
        }
    }
}
