import Foundation
import Observation
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
    /// Whether the search sheet is up.
    var isSearchPresented = false
    /// Whether searches from the search sheet open private tabs.
    var prefersPrivateTabs = false

    let store: TabStore
    /// Page previews for the home screen's tab cards.
    let snapshots: SnapshotStore

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
    @ObservationIgnored private var hasHandledLaunch = false
    /// Cookies and storage shared by private tabs, kept in memory only.
    /// Dropped when the last private tab closes, so the next private
    /// session starts clean.
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    init(store: TabStore) {
        self.store = store
        self.snapshots = SnapshotStore()
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
        guard let url = URLResolver.resolve(input, engine: store.settings.searchEngine) else { return }
        store.openTab(url: url, isPrivate: isPrivate)
        refreshNavigationState()
    }

    /// Shows the search sheet, for "+" and at launch.
    func presentSearch() {
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
    func openTabFromPage(_ url: URL) {
        let opener = store.activeTab
        store.openTab(url: url, in: opener?.spaceID, isPrivate: opener?.isPrivate ?? false)
        refreshNavigationState()
    }

    func activate(_ id: UUID) {
        store.activate(id)
        refreshNavigationState()
    }

    func showHome() {
        guard let id = store.activeTabID, let webView = webViews[id] else {
            store.showHome()
            refreshNavigationState()
            return
        }
        // Snapshot first: once the home screen is up, the web view is off
        // screen and can't be captured.
        Task {
            await snapshots.capture(webView, for: id, savesToDisk: !isPrivateTab(id))
            guard store.activeTabID == id else { return }
            store.showHome()
            refreshNavigationState()
        }
    }

    func dismissSearch() {
        isSearchPresented = false
    }

    /// Keeps the tab's card preview fresh after a page finishes loading.
    func pageDidFinishLoading(in webView: WKWebView) {
        if let id = tabID(for: webView) { paintedTabs.insert(id) }
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

    /// Deletes cookies, caches and site storage for every site.
    func clearBrowsingData() async {
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
