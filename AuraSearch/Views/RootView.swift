import SwiftUI

/// The tab screen when no tab is open, otherwise the browser, with the
/// search panel sliding up over either.
struct RootView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var readerArticle: ReaderArticle?
    /// The screen's height without the keyboard, so the search panel's top
    /// stays put while the keyboard slides up under it.
    @State private var screenHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            screens
                // Only the search panel makes room for the keyboard; the
                // screens behind it shouldn't shift.
                .ignoresSafeArea(.keyboard)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { screenHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in screenHeight = height }
                    }
                }

            if session.isSearchPresented {
                SearchBackdrop { session.dismissSearch() }
                    .transition(.opacity)
                    .zIndex(1)
                VStack(spacing: 0) {
                    // Like Arc: the panel's top sits a little above the middle.
                    Color.clear
                        .frame(height: screenHeight * 0.28)
                        .allowsHitTesting(false)
                    SearchPanel()
                }
                .transition(.move(edge: .bottom))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.9), value: session.isSearchPresented)
        .sheet(item: $readerArticle) { article in
            ReaderView(article: article)
        }
        .task {
            // Like Arc Search: reopen on your last page with search already up.
            if session.consumeLaunchSearch() {
                try? await Task.sleep(for: .milliseconds(300))
                session.presentSearch()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Clean up unused tabs whenever the app comes back to the foreground.
            if phase == .active { session.archiveStaleTabs() }
        }
        .onChange(of: store.settings.appearance) { _, appearance in
            AppearanceController.apply(appearance)
        }
        .onAppear {
            AppearanceController.apply(store.settings.appearance)
        }
    }

    @ViewBuilder
    private var screens: some View {
        Group {
            if let tab = store.activeTab {
                BrowserView(tab: tab, readerArticle: $readerArticle)
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.activeTabID)
    }
}

/// Blurs and dims whatever is behind the search panel. Tap it to close.
private struct SearchBackdrop: View {
    let onTap: () -> Void

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.12))
            .ignoresSafeArea()
            .onTapGesture { onTap() }
            .accessibilityLabel("Close search")
            .accessibilityAddTraits(.isButton)
    }
}
