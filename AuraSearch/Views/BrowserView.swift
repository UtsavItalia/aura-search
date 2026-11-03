import SwiftUI

/// A tab on screen: the page fills the screen, with a small bar below it
/// for Tabs, New Tab and the page menu.
struct BrowserView: View {
    let tab: BrowserTab
    @Binding var readerArticle: ReaderArticle?

    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session

    @State private var showingMenu = false
    /// Something to do once the page menu has finished closing, since a
    /// second sheet or the find bar can't appear while it's still up.
    @State private var afterMenuCloses: MenuFollowUp?
    @State private var readerMessage: String?

    private enum MenuFollowUp {
        case reader
        case find
    }

    private var tint: Color {
        store.space(withID: tab.spaceID)?.color.color ?? .accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab.isPrivate {
                Label("Private", systemImage: "eye.slash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.black)
            }
            WebViewContainer(webView: session.webView(for: tab))
                .overlay { loadingSnapshot }
                .animation(.easeOut(duration: 0.25), value: session.paintedTabs.contains(tab.id))
            bottomBar
        }
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
                onFind: { closeMenu(then: .find) }
            )
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

    /// The tab's last snapshot, shown until a reloading page has drawn,
    /// so opening a tab never flashes a blank page.
    @ViewBuilder
    private var loadingSnapshot: some View {
        if !session.paintedTabs.contains(tab.id), let snapshot = session.snapshots.images[tab.id] {
            Image(uiImage: snapshot)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            circleButton("square.on.square", label: "Tabs") {
                session.showHome()
            }
            Spacer()
            Button {
                session.presentSearch()
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 104, height: 52)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .accessibilityLabel("New tab")
            Spacer()
            circleButton("chevron.up", label: "Page menu") {
                showingMenu = true
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 4)
        // Charcoal on private tabs, like Arc; the system bar otherwise.
        .browserBar(isPrivate: tab.isPrivate)
        .overlay(alignment: .top) {
            if session.isLoading {
                ProgressView(value: session.progress)
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
        }
        // Swiping up on the bar opens the menu too.
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { showingMenu = true }
            }
        )
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .frame(width: 52, height: 52)
                .background(Color.primary.opacity(0.1), in: Circle())
        }
        .accessibilityLabel(label)
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
        }
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
