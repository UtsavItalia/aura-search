import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

/// Owns the live web views and the actions the UI performs on tabs.
///
/// `TabStore` is the saved data; this is the running browser. Each tab gets
/// its own `WKWebView`, kept alive while you switch between tabs. Only a few
/// stay in memory at once: the least recently used one is dropped and its
/// back/forward history saved, then rebuilt when you return to that tab.
@MainActor
@Observable
final class BrowserSession {
    // Navigation state of the tab on screen, for the toolbar and page menu.
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var pageZoom: CGFloat = 1
    /// Tabs showing the desktop version of sites.
    private(set) var desktopSiteTabs: Set<UUID> = []
    /// Tabs whose web view has drawn its page. Until then the browser shows
    /// the tab's snapshot, instead of a blank page while it reloads.
    private(set) var paintedTabs: Set<UUID> = []
    /// The page shrinking into its card, or a card growing into its page,
    /// while you move between a tab and the tab screen. `nil` when still.
    private(set) var transition: TabTransition?
    /// Whether the search panel is up.
    private(set) var isSearchPresented = false
    /// True while the panel slides down with the keyboard on its way out.
    /// It's removed once it's out of sight.
    private(set) var isSearchClosing = false
    /// Whether searches from the search sheet open private tabs.
    var prefersPrivateTabs = false
    /// The tab whose summary sheet is up, if any.
    var summaryTabID: UUID?
    /// A new page arriving, from a search or a link that opens a tab: it
    /// grows into place instead of appearing all at once.
    private(set) var arrival: Arrival?
    /// A picture of the page a link is leaving, held over the web view until
    /// the next page has drawn and then faded out, so pages crossfade
    /// instead of blinking from one to the next.
    private(set) var pageCovers: [UUID: UIImage] = [:]
    /// The tab whose web view is kept out of the window while its card
    /// grows into the page, with the card's picture drawn in its place.
    /// See `holdBack(_:)`.
    private(set) var heldBackTabID: UUID?

    let store: TabStore
    /// Page previews for the home screen's tab cards.
    let snapshots: SnapshotStore
    /// Pages you've visited, for autocomplete and the History screen.
    let history: HistoryStore
    /// Files downloaded from pages.
    let downloads: DownloadManager

    /// How many web views to keep alive. Each one is a separate WebKit
    /// process's worth of memory, so this stays small.
    static let maxLiveWebViews = 6
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0

    private let contentBlocker: ContentBlocker
    private let delegate: WebViewDelegate
    @ObservationIgnored private var webViews: [UUID: WKWebView] = [:]
    @ObservationIgnored private var recentlyUsed: [UUID] = []
    @ObservationIgnored private var observations: [UUID: [NSKeyValueObservation]] = [:]
    /// Back/forward history of web views dropped to save memory.
    @ObservationIgnored private var savedStates: [UUID: Any] = [:]
    /// Pinch to summarize, one per live web view. Gesture recognizers don't
    /// keep their targets alive, so they're kept here.
    @ObservationIgnored private var pinchHandlers: [UUID: PinchToSummarize] = [:]
    /// Tells the session when a page has drawn. Shared by every web view; it
    /// holds the session weakly, since content controllers keep their
    /// handlers alive.
    private let readyHandler: PageReadyHandler
    /// Pictures of pages being left, taken when a link is tapped, waiting
    /// for the next page to commit.
    @ObservationIgnored private var leavingPictures: [UUID: UIImage] = [:]
    @ObservationIgnored private var pictureTasks: [UUID: Task<Void, Never>] = [:]
    /// Tabs whose cover is up: they count as drawn only once the page says
    /// so (or a moment passes), not on load progress alone.
    @ObservationIgnored private var coveredTabs: Set<UUID> = []
    @ObservationIgnored private var coverTimeouts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hasHandledLaunch = false
    /// The tab each new tab was opened from, for going back to it if the
    /// new tab turns out to be only a download.
    @ObservationIgnored private var openers: [UUID: UUID] = [:]
    /// Bumped whenever the search panel opens or starts closing, so a close
    /// that's been overtaken by a reopen doesn't remove the panel.
    @ObservationIgnored private var searchGeneration = 0
    /// The screen, as measured by the root view, for working out where a
    /// page's card will be before the tab screen is on screen.
    @ObservationIgnored var metrics = ScreenMetrics()
    /// Cookies and storage shared by private tabs, kept in memory only.
    /// Dropped when the last private tab closes, so the next private
    /// session starts clean.
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    init(store: TabStore) {
        self.store = store
        self.snapshots = SnapshotStore()
        self.history = HistoryStore()
        self.downloads = DownloadManager()
        self.contentBlocker = ContentBlocker()
        self.delegate = WebViewDelegate()
        self.readyHandler = PageReadyHandler()
        delegate.session = self
        readyHandler.session = self
    }

    /// Call once at launch.
    func prepare() async {
        await contentBlocker.load()
        applyContentBlocking()
        archiveStaleTabs()
    }

    // MARK: - Web views

    /// The web view for a tab, created on first use.
    func webView(for tab: BrowserTab) -> WKWebView {
        if let existing = webViews[tab.id] {
            markUsed(tab.id)
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        if tab.isPrivate {
            let dataStore = privateDataStore ?? .nonPersistent()
            privateDataStore = dataStore
            configuration.websiteDataStore = dataStore
        } else {
            configuration.websiteDataStore = .default()
        }

        // Lets the page say when it has drawn, from a script world the
        // page's own scripts can't see.
        configuration.userContentController.addUserScript(PageReadyHandler.script)
        configuration.userContentController.add(readyHandler, contentWorld: .defaultClient, name: PageReadyHandler.name)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        applyContentBlocking(to: webView, host: tab.url?.host())
        let tabID = tab.id
        pinchHandlers[tabID] = PinchToSummarize(webView: webView) { [weak self] in
            self?.requestSummary(for: tabID) ?? false
        }

        webViews[tab.id] = webView
        observe(webView, tabID: tab.id)
        markUsed(tab.id)
        evictIfNeeded()

        let savedState = savedStates.removeValue(forKey: tab.id)
        let url = tab.url
        // Deferred so loading never starts in the middle of a SwiftUI view update.
        Task { @MainActor in
            if let savedState {
                webView.interactionState = savedState
            } else if let url {
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    var activeWebView: WKWebView? {
        guard let id = store.activeTabID else { return nil }
        return webViews[id]
    }

    private func tabID(for webView: WKWebView) -> UUID? {
        webViews.first { $0.value === webView }?.key
    }

    private func markUsed(_ id: UUID) {
        recentlyUsed.removeAll { $0 == id }
        recentlyUsed.append(id)
    }

    private func evictIfNeeded() {
        while webViews.count > Self.maxLiveWebViews,
              let victim = recentlyUsed.first(where: { $0 != store.activeTabID }) {
            if let webView = webViews[victim] {
                savedStates[victim] = webView.interactionState
            }
            // Eviction runs while SwiftUI is building the view, so the
            // observable part of the clean-up waits until it's done.
            discardWebView(victim, deferringObservedChanges: true)
        }
    }

    private func discardWebView(_ id: UUID, deferringObservedChanges: Bool = false) {
        observations[id] = nil // invalidates the KVO observations
        pinchHandlers[id] = nil
        clearCover(for: id)
        if let webView = webViews.removeValue(forKey: id) {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: PageReadyHandler.name,
                contentWorld: .defaultClient
            )
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        recentlyUsed.removeAll { $0 == id }
        if deferringObservedChanges {
            Task { @MainActor [weak self] in
                guard let self, self.webViews[id] == nil else { return }
                self.paintedTabs.remove(id)
                if self.pageCovers[id] != nil { self.pageCovers[id] = nil }
                if self.heldBackTabID == id { self.heldBackTabID = nil }
            }
        } else {
            paintedTabs.remove(id)
            if pageCovers[id] != nil { pageCovers[id] = nil }
            if heldBackTabID == id { heldBackTabID = nil }
        }
    }

    /// Drops everything kept for a tab that was closed.
    private func forget(_ id: UUID) {
        savedStates[id] = nil
        openers[id] = nil
        if summaryTabID == id { summaryTabID = nil }
        desktopSiteTabs.remove(id)
        snapshots.remove(id)
        discardWebView(id)
        if !store.tabs.contains(where: \.isPrivate) {
            privateDataStore = nil
        }
    }

    // MARK: - Watching pages

    private func observe(_ webView: WKWebView, tabID: UUID) {
        observations[tabID] = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageInfoChanged(tabID) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageInfoChanged(tabID) }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.navigationStateChanged(tabID) }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.navigationStateChanged(tabID) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.navigationStateChanged(tabID) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.navigationStateChanged(tabID) }
            },
        ]
    }

    private func pageInfoChanged(_ tabID: UUID) {
        guard let webView = webViews[tabID] else { return }
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        store.updateTab(tabID, url: webView.url, title: title)
        if let title, let url = webView.url, !isPrivateTab(tabID) {
            history.updateTitle(title, for: url)
        }
    }

    private func navigationStateChanged(_ tabID: UUID) {
        // A covered page waits for its own "drawn" signal: load progress can
        // run ahead of what's on screen, and lifting the cover early would
        // show the old page again before the new one blinks in.
        if !paintedTabs.contains(tabID), !coveredTabs.contains(tabID), let webView = webViews[tabID] {
            // Most of the page is in by 80%; a finished or failed load counts too.
            let progress = webView.estimatedProgress
            if progress >= 0.8 || (!webView.isLoading && progress > 0) {
                paintedTabs.insert(tabID)
            }
        }
        guard tabID == store.activeTabID else { return }
        refreshNavigationState()
    }

    /// Syncs the toolbar state with the tab on screen.
    func refreshNavigationState() {
        let webView = activeWebView
        // Only assign real changes: progress fires many times per load.
        if canGoBack != (webView?.canGoBack ?? false) { canGoBack = webView?.canGoBack ?? false }
        if canGoForward != (webView?.canGoForward ?? false) { canGoForward = webView?.canGoForward ?? false }
        if isLoading != (webView?.isLoading ?? false) { isLoading = webView?.isLoading ?? false }
        if pageZoom != (webView?.pageZoom ?? 1) { pageZoom = webView?.pageZoom ?? 1 }
        let newProgress = webView?.estimatedProgress ?? 0
        if abs(progress - newProgress) > 0.01 || newProgress == 1 { progress = newProgress }
    }

    // MARK: - Opening and moving between tabs

    /// Opens what was typed in a new tab, in the current Space.
    func openNewTab(from input: String, isPrivate: Bool = false) {
        let engine = store.settings.searchEngine
        guard let url = URLResolver.resolve(input, engine: engine) else { return }
        // An address you typed yourself ranks higher in autocomplete.
        if !isPrivate, url != engine.searchURL(for: input.trimmingCharacters(in: .whitespacesAndNewlines)) {
            history.recordTyped(url)
        }
        let previous = store.activeTabID
        let tab = store.openTab(url: url, isPrivate: isPrivate)
        if let previous { openers[tab.id] = previous }
        beginArrival(of: tab.id)
        refreshNavigationState()
    }

    /// Shows the search panel, for "+" and at launch.
    func presentSearch() {
        searchGeneration += 1
        if isSearchClosing {
            withAnimation(Motion.present) { isSearchClosing = false }
        }
        isSearchPresented = true
    }

    /// True once, at launch, if the search sheet should open by itself
    /// (the Auto-Open Keyboard setting).
    func consumeLaunchSearch() -> Bool {
        guard !hasHandledLaunch else { return false }
        hasHandledLaunch = true
        return store.settings.autoOpenKeyboard
    }

    /// Loads what was typed in the tab on screen.
    func navigateActiveTab(to input: String) {
        guard let url = URLResolver.resolve(input, engine: store.settings.searchEngine) else { return }
        guard let webView = activeWebView else {
            openNewTab(from: input)
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Links that open a new window stay private if they came from a private tab.
    func openTabFromPage(_ url: URL, openedBy webView: WKWebView? = nil) {
        let openerID = webView.flatMap { tabID(for: $0) } ?? store.activeTabID
        let opener = store.tabs.first { $0.id == openerID }
        let tab = store.openTab(url: url, in: opener?.spaceID, isPrivate: opener?.isPrivate ?? false)
        if let opener { openers[tab.id] = opener.id }
        beginArrival(of: tab.id)
        refreshNavigationState()
    }

    /// A page has started a download. If that was all a new tab was opened
    /// for, the tab would sit there blank, so it closes and you're back on
    /// the page you came from, as in Safari.
    func downloadStarted(in webView: WKWebView) {
        guard webView.backForwardList.currentItem == nil,
              let id = tabID(for: webView) else { return }
        // A moment later, once WebKit has handed the load over to the download.
        Task { @MainActor [weak self] in
            guard let self, self.store.tabs.contains(where: { $0.id == id }) else { return }
            let opener = self.openers[id]
            let wasOnScreen = self.store.activeTabID == id
            self.store.discardTab(id)
            self.forget(id)
            if wasOnScreen, let opener, self.store.tabs.contains(where: { $0.id == opener }) {
                self.store.activate(opener)
            }
            self.refreshNavigationState()
        }
    }

    /// Opens the summary sheet for the tab on screen: from the page menu, or
    /// by pinching the page in past its smallest zoom. Returns whether it opened.
    @discardableResult
    func requestSummary(for tabID: UUID) -> Bool {
        guard PageSummarizer.isOffered,
              store.activeTabID == tabID,
              transition == nil,
              !isSearchPresented else { return false }
        summaryTabID = tabID
        return true
    }

    /// Opens a tab straight away, with no zoom: from search, history and
    /// the archive.
    func activate(_ id: UUID) {
        guard transition == nil else { return }
        store.activate(id)
        refreshNavigationState()
    }

    // MARK: - Moving between a page and the tab screen

    /// The page shrinking into its card, or a card growing into its page.
    struct TabTransition: Equatable {
        enum Direction {
            case toDeck
            case toPage
        }

        let tabID: UUID
        let direction: Direction
        /// 0 is the full page, 1 the card in the deck. Animated in between.
        var progress: CGFloat
        /// Where the card's page is on screen.
        let cardRect: CGRect
        /// Where the deck rests meanwhile.
        let deckPosition: CGFloat
    }

    /// Back to the tab screen: the live page shrinks into its card while
    /// the other cards fly out of the tabs button, as in Arc.
    func showHome() {
        guard transition == nil else { return }
        guard let tab = store.activeTab else {
            store.showHome()
            refreshNavigationState()
            return
        }
        let id = tab.id
        let webView = webViews[id]
        // The tab you leave becomes the front card, so the deck you land on
        // is ordered by use, like Arc's. Done before the deck is drawn, so
        // no card is seen changing places.
        store.moveToFront(id)
        // The card needs a fresh picture of the page. Taken now, while the
        // page is still on screen, alongside the animation rather than before it.
        let capture: Task<Void, Never>? = webView.map { webView in
            let savesToDisk = !tab.isPrivate
            return Task { [snapshots = self.snapshots] in
                guard let image = await snapshots.captureImage(of: webView) else { return }
                await snapshots.keep(image, for: id, savesToDisk: savesToDisk)
            }
        }

        let tabs = store.tabs(in: tab.spaceID)
        guard metrics.isValid, webView != nil, let index = tabs.firstIndex(where: { $0.id == id }) else {
            store.showHome()
            refreshNavigationState()
            return
        }
        let position = DeckLayout.openingPosition(currentIndex: index, count: tabs.count)
        transition = TabTransition(
            tabID: id,
            direction: .toDeck,
            progress: 0,
            cardRect: DeckLayout.previewRect(u: CGFloat(index) - position, in: metrics),
            deckPosition: position
        )
        // Next frame, once the tab screen is drawn under the page.
        Task {
            withAnimation(Motion.zoom) {
                transition?.progress = 1
            } completion: { [weak self] in
                Task { @MainActor [weak self] in
                    // The card shows the new picture the moment the page goes,
                    // but never waits more than a moment for it.
                    if let capture {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await capture.value }
                            group.addTask { try? await Task.sleep(for: .milliseconds(400)) }
                            _ = await group.next()
                            group.cancelAll()
                        }
                    }
                    guard let self, self.transition?.tabID == id else { return }
                    self.store.showHome()
                    self.transition = nil
                    self.refreshNavigationState()
                }
            }
        }
    }

    /// From the tab screen: the card grows into the live page.
    /// - Parameter cardRect: where the card's page is on screen right now.
    func open(_ id: UUID, fromCard cardRect: CGRect, deckPosition: CGFloat) {
        guard transition == nil else { return }
        guard metrics.isValid else {
            activate(id)
            return
        }
        transition = TabTransition(
            tabID: id,
            direction: .toPage,
            progress: 1,
            cardRect: cardRect,
            deckPosition: deckPosition
        )
        let heldBack = holdBack(id)
        store.activate(id)
        refreshNavigationState()
        Task {
            withAnimation(Motion.zoom) {
                transition?.progress = 0
            } completion: { [weak self] in
                guard let self else { return }
                if self.transition?.tabID == id { self.transition = nil }
                if heldBack { self.release(id) }
            }
        }
    }

    /// Closes the search panel. The keyboard starts down straight away and
    /// the panel rides down on it, slipping behind it, so the two leave as
    /// one, like Arc. Left to SwiftUI, the keyboard only went once the text
    /// field had been removed, trailing behind the panel.
    func dismissSearch() {
        guard isSearchPresented, !isSearchClosing else { return }
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        searchGeneration += 1
        let generation = searchGeneration
        withAnimation(Motion.dismiss) {
            isSearchClosing = true
        } completion: { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            // Out of sight by now, so it just goes.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.isSearchPresented = false
                self.isSearchClosing = false
            }
        }
    }

    /// Keeps the tab's card preview fresh after a page finishes loading,
    /// and records the visit (never for private tabs).
    func pageDidFinishLoading(in webView: WKWebView) {
        if let id = tabID(for: webView) {
            pageDidPaint(id)
            if !isPrivateTab(id), let url = webView.url {
                history.recordVisit(url: url, title: webView.title)
            }
        }
        guard let id = store.activeTabID, webViews[id] === webView else { return }
        Task { await snapshots.capture(webView, for: id, savesToDisk: !isPrivateTab(id)) }
    }

    private func isPrivateTab(_ id: UUID) -> Bool {
        store.tabs.first { $0.id == id }?.isPrivate ?? false
    }

    // MARK: - Pages arriving and changing

    /// A new page arriving. 0 as it starts, 1 once it's in place.
    struct Arrival: Equatable {
        let tabID: UUID
        var progress: CGFloat
    }

    /// Grows a tab that just opened into place, starting in the same update
    /// that puts it on screen, so its first frame is already the start.
    private func beginArrival(of id: UUID) {
        guard metrics.isValid else { return }
        arrival = Arrival(tabID: id, progress: 0)
        // Next frame, once the page is drawn at its starting point.
        Task {
            withAnimation(Motion.arrive) {
                arrival?.progress = 1
            } completion: { [weak self] in
                if self?.arrival?.tabID == id { self?.arrival = nil }
            }
        }
    }

    /// A link was tapped (or a form sent) in the page on screen: takes a
    /// picture of the page now, to hold over the next one until it draws.
    /// Back and forward swipes keep WebKit's own animation, and reloads
    /// aren't changes of page.
    func navigationStarting(in webView: WKWebView, type: WKNavigationType) {
        guard type == .linkActivated || type == .formSubmitted || type == .other,
              let id = tabID(for: webView),
              id == store.activeTabID,
              transition == nil,
              webView.url != nil else { return }
        // A newer tap (or a redirect asking again) takes a fresh picture.
        pictureTasks[id]?.cancel()
        leavingPictures[id] = nil
        pictureTasks[id] = Task { [weak self, snapshots = self.snapshots] in
            let picture = await snapshots.captureImage(of: webView)
            guard let self, !Task.isCancelled else { return }
            guard let picture else {
                self.pictureTasks[id] = nil
                return
            }
            self.leavingPictures[id] = picture
            // A link to a spot on the same page never commits a new one:
            // don't keep a whole-screen picture around for it.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self.leavingPictures[id] === picture { self.leavingPictures[id] = nil }
            self.pictureTasks[id] = nil
        }
    }

    /// The next page has replaced the old one in WebKit, which keeps showing
    /// the old one until the new one first draws. The picture goes up now,
    /// without a fade, so the swap underneath can't be seen.
    func navigationCommitted(in webView: WKWebView) {
        guard let id = tabID(for: webView) else { return }
        pictureTasks[id]?.cancel()
        pictureTasks[id] = nil
        guard let picture = leavingPictures.removeValue(forKey: id),
              id == store.activeTabID,
              transition == nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageCovers[id] = picture
            coveredTabs.insert(id)
            paintedTabs.remove(id)
        }
        // Never holds the old page up long, even if the new one is slow to
        // say it has drawn.
        coverTimeouts[id]?.cancel()
        coverTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.pageDidPaint(id)
        }
    }

    /// The navigation didn't happen (an error, or a download instead): no
    /// crossfade, and nothing left covering the page.
    func navigationFailed(in webView: WKWebView) {
        guard let id = tabID(for: webView) else { return }
        pictureTasks[id]?.cancel()
        pictureTasks[id] = nil
        leavingPictures[id] = nil
        if coveredTabs.contains(id) { pageDidPaint(id) }
    }

    /// Opening a card whose web view is still alive. Putting the web view
    /// back in the window as the card starts to grow went wrong twice over
    /// (both seen frame by frame in a screen recording):
    /// - WebKit lets go of an off-screen page's drawing, so the page showed
    ///   blank white until it drew again (about 100 ms);
    /// - WebKit waits on the main thread for the page to draw when it goes
    ///   back in a window, which froze the zoom for a frame or two.
    ///
    /// So the web view stays out of the window while the card grows, with
    /// the card's picture drawn where the page will be, and goes back in
    /// once the zoom is over (`release(_:)`), when a pause can't be seen.
    /// Returns false when there's no picture to show: the web view then
    /// goes in at once, as before. Web views being rebuilt already wait for
    /// their first paint, so they're left alone too.
    private func holdBack(_ id: UUID) -> Bool {
        // The loading cover only shows for a tab with an address.
        guard webViews[id] != nil,
              paintedTabs.contains(id),
              snapshots.images[id] != nil,
              store.tabs.contains(where: { $0.id == id && $0.url != nil }) else { return false }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            coveredTabs.insert(id)
            paintedTabs.remove(id)
            heldBackTabID = id
        }
        return true
    }

    /// The zoom is over: the held-back web view goes into the window, and
    /// the picture over it fades once the page has drawn there.
    private func release(_ id: UUID) {
        guard heldBackTabID == id else { return }
        heldBackTabID = nil
        // Counted from now, not from the tap, so the page gets its time.
        coverTimeouts[id]?.cancel()
        coverTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.pageDidPaint(id)
        }
        guard let webView = webViews[id] else { return }
        Task { [weak self, weak webView] in
            // Animation frames only run once the page is drawing in the
            // window again, so two of them mean it's back on screen.
            // If the script can't run (no JavaScript on the page), the
            // timeout lifts the cover instead.
            do {
                _ = try await webView?.callAsyncJavaScript(
                    "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                    contentWorld: .defaultClient
                )
            } catch { return }
            guard let self, self.coveredTabs.contains(id) else { return }
            self.pageDidPaint(id)
        }
    }

    /// The page's script reported that it has drawn its first frames.
    func pageReady(in webView: WKWebView) {
        guard let id = tabID(for: webView) else { return }
        pageDidPaint(id)
    }

    /// The page on screen has drawn: whatever covers it fades away (the view
    /// animates on `paintedTabs`), and the picture goes once it's faded.
    private func pageDidPaint(_ id: UUID) {
        // Out of the window, nothing has drawn where it can be seen (a load
        // finishing mid-zoom would otherwise lift the picture over an empty
        // page). `release(_:)` takes over once the web view is back in.
        guard heldBackTabID != id else { return }
        coveredTabs.remove(id)
        coverTimeouts[id]?.cancel()
        coverTimeouts[id] = nil
        if !paintedTabs.contains(id) { paintedTabs.insert(id) }
        guard pageCovers[id] != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.paintedTabs.contains(id) else { return }
            self.pageCovers[id] = nil
        }
    }

    /// Drops a tab's crossfade bookkeeping. The cover itself, which views
    /// observe, is removed by the caller when it's safe to change state.
    private func clearCover(for id: UUID) {
        pictureTasks[id]?.cancel()
        pictureTasks[id] = nil
        coverTimeouts[id]?.cancel()
        coverTimeouts[id] = nil
        leavingPictures[id] = nil
        coveredTabs.remove(id)
    }

    // MARK: - Page actions

    func goBack() { activeWebView?.goBack() }
    func goForward() { activeWebView?.goForward() }
    func reload() { activeWebView?.reload() }
    func stopLoading() { activeWebView?.stopLoading() }

    func presentFindOnPage() {
        activeWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func copyActiveLink() {
        guard let url = activeWebView?.url ?? store.activeTab?.url else { return }
        UIPasteboard.general.url = url
    }

    func adjustZoom(by delta: CGFloat) {
        guard let webView = activeWebView else { return }
        let zoom = (webView.pageZoom + delta).clamped(to: Self.zoomRange)
        webView.pageZoom = (zoom * 10).rounded() / 10
        refreshNavigationState()
    }

    func resetZoom() {
        activeWebView?.pageZoom = 1
        refreshNavigationState()
    }

    /// Switches the tab on screen between the mobile and desktop site.
    func toggleDesktopSite() {
        guard let id = store.activeTabID else { return }
        if desktopSiteTabs.contains(id) {
            desktopSiteTabs.remove(id)
        } else {
            desktopSiteTabs.insert(id)
        }
        // A fresh load of the same address, so the new content mode applies.
        if let webView = activeWebView, let url = webView.url {
            webView.load(URLRequest(url: url))
        }
    }

    /// Used by the navigation delegate before each main-frame load.
    func prefersDesktopSite(_ webView: WKWebView) -> Bool {
        guard let id = tabID(for: webView) else { return false }
        return desktopSiteTabs.contains(id)
    }

    // MARK: - Closing and archiving

    func closeTab(_ id: UUID) {
        store.closeTab(id)
        forget(id)
        refreshNavigationState()
    }

    func closeUnpinnedTabs(in spaceID: UUID) {
        for id in store.closeUnpinnedTabs(in: spaceID) { forget(id) }
        refreshNavigationState()
    }

    func deleteSpace(_ id: UUID) {
        for tabID in store.deleteSpace(id) { forget(tabID) }
        refreshNavigationState()
    }

    func restore(_ archivedID: UUID) {
        store.restore(archivedID)
        refreshNavigationState()
    }

    func archiveStaleTabs() {
        for id in store.archiveStaleTabs() { forget(id) }
    }

    // MARK: - Reader

    func readerArticle() async -> ReaderArticle? {
        guard let webView = activeWebView else { return nil }
        return await ReaderMode.extract(from: webView)
    }

    // MARK: - Tracker blocking

    /// Re-applies the tracker blocker to every open tab, after the setting
    /// changes. Takes effect from each tab's next page load.
    func applyContentBlocking() {
        for webView in webViews.values {
            applyContentBlocking(to: webView, host: webView.url?.host())
        }
    }

    /// Adds or removes the tracker list for the site a web view is about to load.
    func applyContentBlocking(to webView: WKWebView, host: String?) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if store.settings.isBlockingTrackers(on: host), let rules = contentBlocker.ruleList {
            controller.add(rules)
        }
    }

    /// Turns blocking off (or back on) for the site on screen and reloads it,
    /// for when blocking breaks a page.
    func setTrackerBlockingForActiveSite(_ enabled: Bool) {
        guard let webView = activeWebView, let host = webView.url?.host() else { return }
        store.setTrackerBlocking(enabled, forHost: host)
        applyContentBlocking(to: webView, host: host)
        webView.reload()
    }

    // MARK: - App links and site data

    /// If links open in apps and an installed app handles this link, opens
    /// it there and returns true. Links within the same site stay here.
    func openInAppIfPossible(_ url: URL, from webView: WKWebView) async -> Bool {
        guard store.settings.opensLinksInApps,
              let host = url.host(),
              host != webView.url?.host() else { return false }
        return await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
    }

    /// Deletes history, cookies, caches and site storage for every site.
    func clearBrowsingData() async {
        history.clear()
        let dataStore = WKWebsiteDataStore.default()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        URLCache.shared.removeAllCachedResponses()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Lets a page tell the session it has drawn: a script, in a world of its
/// own that the page's scripts can't see or call, posts once the page has
/// laid out and painted its first frames.
///
/// Content controllers keep their message handlers alive, so this holds the
/// session weakly rather than being the session itself.
@MainActor
final class PageReadyHandler: NSObject, WKScriptMessageHandler {
    static let name = "auraPageReady"

    weak var session: BrowserSession?

    /// After the page's HTML is in, two animation frames: the first is laid
    /// out, the second means it has been painted.
    static var script: WKUserScript {
        WKUserScript(
            source: """
            (function () {
              function ready() {
                requestAnimationFrame(function () {
                  requestAnimationFrame(function () {
                    try { window.webkit.messageHandlers.\(name).postMessage(1); } catch (e) {}
                  });
                });
              }
              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", ready, { once: true });
              } else {
                ready();
              }
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        session?.pageReady(in: webView)
    }
}
