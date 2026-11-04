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
        delegate.session = self
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
        if let webView = webViews.removeValue(forKey: id) {
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
            }
        } else {
            paintedTabs.remove(id)
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
        if !paintedTabs.contains(tabID), let webView = webViews[tabID] {
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
        refreshNavigationState()
    }

    /// How the search panel comes up, and comes back if reopened on its way out.
    static let searchAnimation = Animation.spring(response: 0.36, dampingFraction: 0.9)
    /// How it leaves: about as long as the keyboard takes, with no bounce.
    static let searchCloseAnimation = Animation.spring(duration: 0.3, bounce: 0)

    /// Shows the search panel, for "+" and at launch.
    func presentSearch() {
        searchGeneration += 1
        if isSearchClosing {
            withAnimation(Self.searchAnimation) { isSearchClosing = false }
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

    /// Quick with a soft landing, like the iOS app switcher.
    static let transitionAnimation = Animation.spring(duration: 0.36, bounce: 0.1)

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
            withAnimation(Self.transitionAnimation) {
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
        store.activate(id)
        refreshNavigationState()
        Task {
            withAnimation(Self.transitionAnimation) {
                transition?.progress = 0
            } completion: { [weak self] in
                if self?.transition?.tabID == id { self?.transition = nil }
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
        withAnimation(Self.searchCloseAnimation) {
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
            paintedTabs.insert(id)
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
