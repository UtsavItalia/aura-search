import QuickLook
import SwiftUI

/// The tab screen and the page on top of it, with the search panel sliding
/// up over either.
///
/// Both screens are laid out in screen coordinates from one measurement,
/// so a page and its card line up exactly as one turns into the other.
struct RootView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var readerArticle: ReaderArticle?
    @State private var metrics = ScreenMetrics()
    /// The whole screen, and the part of it inside the status bar and home
    /// indicator, both in screen coordinates. Measured as plain frames: no
    /// safe-area insets are read during layout, so nothing can loop.
    @State private var screenFrame: CGRect = .zero
    @State private var safeFrame: CGRect = .zero

    var body: some View {
        ZStack {
            // A full-screen surface, status bar, home indicator and keyboard
            // area included. Its size never depends on what's drawn on it,
            // so measuring it can't feed back into itself.
            Color.clear
                .ignoresSafeArea()
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .global)
                        Color.clear
                            .onAppear { screenFrame = frame; remeasure() }
                            .onChange(of: frame) { _, newFrame in screenFrame = newFrame; remeasure() }
                    }
                    .ignoresSafeArea()
                }
                // The screens sit on it in an overlay, which can't change its
                // size. The keyboard never moves them; only the search panel
                // rides on it.
                .overlay(alignment: .topLeading) {
                    screens
                        .environment(\.screenMetrics, metrics)
                }

            // The safe area, which the keyboard doesn't change.
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { safeFrame = frame; remeasure() }
                    .onChange(of: frame) { _, newFrame in safeFrame = newFrame; remeasure() }
            }
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(false)

            // Its own view, so download progress redraws only the card.
            DownloadToastLayer(metrics: metrics)

            searchLayer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.screenMetrics, metrics)
        }
        .sheet(item: $readerArticle) { article in
            ReaderView(article: article)
        }
        .sheet(isPresented: showingDownloads) {
            DownloadsView()
                .environment(store)
                .environment(session)
        }
        .quickLookPreview(previewingDownload)
        .task {
            // Like Arc Search: reopen on your last page with search already up.
            if session.consumeLaunchSearch() {
                try? await Task.sleep(for: .milliseconds(300))
                session.presentSearch()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Clean up unused tabs whenever the app comes back to the foreground.
                session.archiveStaleTabs()
            case .background:
                store.saveNow()
                session.history.saveNow()
            default:
                break
            }
        }
        .onChange(of: store.settings.appearance) { _, appearance in
            AppearanceController.apply(appearance)
        }
        .onAppear {
            AppearanceController.apply(store.settings.appearance)
        }
    }

    /// The tab screen sits under the page. Both are on screen only while one
    /// turns into the other; otherwise they swap instantly, never crossfade.
    private var screens: some View {
        ZStack(alignment: .topLeading) {
            if store.activeTabID == nil || session.transition != nil {
                HomeView()
                    .transition(.identity)
            }
            if let tab = store.activeTab {
                BrowserView(tab: tab, readerArticle: $readerArticle)
                    .transition(.identity)
            }
        }
    }

    private var searchLayer: some View {
        let closing = session.isSearchClosing
        return ZStack(alignment: .bottom) {
            if session.isSearchPresented {
                SearchBackdrop(isDark: colorScheme == .dark) { session.dismissSearch() }
                    .opacity(closing ? 0 : 1)
                    .transition(.opacity)
                // Pinned to the top of the keyboard, so the two slide up and
                // down together as one piece, like Arc. On the way out it
                // also sinks by its own height, so it's gone when the
                // keyboard is, instead of being left sitting at the bottom.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SearchPanel()
                        .frame(height: panelHeight)
                        .offset(y: closing ? panelHeight + metrics.safeBottom + 24 : 0)
                        .allowsHitTesting(!closing)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .animation(Motion.present, value: session.isSearchPresented)
    }

    private var showingDownloads: Binding<Bool> {
        Binding(
            get: { session.downloads.isListPresented },
            set: { session.downloads.isListPresented = $0 }
        )
    }

    private var previewingDownload: Binding<URL?> {
        Binding(
            get: { session.downloads.previewURL },
            set: { session.downloads.previewURL = $0 }
        )
    }

    /// Arc's panel stands about a third of the screen tall above the keyboard.
    private var panelHeight: CGFloat {
        metrics.isValid ? max(metrics.height * 0.316, 260) : 300
    }

    private func remeasure() {
        guard screenFrame.width > 0, screenFrame.height > 0,
              safeFrame.width > 0, safeFrame.height > 0 else { return }
        let measured = ScreenMetrics(
            width: screenFrame.width,
            height: screenFrame.height,
            safeTop: max(safeFrame.minY - screenFrame.minY, 0),
            safeBottom: max(screenFrame.maxY - safeFrame.maxY, 0)
        )
        guard measured.isValid, measured != metrics else { return }
        metrics = measured
        session.metrics = measured
    }
}

/// The latest download, in a card just above the bottom bar, in screen
/// coordinates like the bar itself.
private struct DownloadToastLayer: View {
    let metrics: ScreenMetrics
    @Environment(BrowserSession.self) private var session

    var body: some View {
        let downloads = session.downloads
        ZStack(alignment: .topLeading) {
            if let item = downloads.toastItem, metrics.isValid {
                DownloadToast(
                    item: item,
                    onOpen: { downloads.preview(item) },
                    onShowList: {
                        downloads.dismissToast()
                        downloads.isListPresented = true
                    },
                    onDismiss: { downloads.dismissToast() }
                )
                .padding(.horizontal, 12)
                .frame(width: metrics.width)
                .position(x: metrics.width / 2, y: metrics.barTop - 40)
                .transition(.offset(y: 24).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(Motion.standard, value: downloads.toastID)
    }
}

/// Dims whatever is behind the search panel, like Arc. Only a dim, no
/// blur: blurring a live page is costly and made the motion stutter.
private struct SearchBackdrop: View {
    let isDark: Bool
    let onTap: () -> Void

    var body: some View {
        Color.black.opacity(isDark ? 0.4 : 0.24)
            .ignoresSafeArea()
            .onTapGesture { onTap() }
            .accessibilityLabel("Close search")
            .accessibilityAddTraits(.isButton)
    }
}
