import UIKit
import WebKit

/// Handles the web view callbacks that need app-level decisions.
@MainActor
final class WebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var session: BrowserSession?

    /// Schemes the web view loads itself. Anything else (mailto:, tel:,
    /// App Store links...) is handed to iOS.
    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]

    // Links with target="_blank" and window.open() become a new tab,
    // the way Arc Search handled them.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            session?.openTabFromPage(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else { return (.allow, preferences) }

        guard Self.webSchemes.contains(scheme) else {
            // Only open other apps when the user tapped a link, so pages can't
            // launch apps on their own.
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return (.cancel, preferences)
        }

        guard let session, navigationAction.targetFrame?.isMainFrame ?? true else {
            return (.allow, preferences)
        }

        if navigationAction.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           await session.openInAppIfPossible(url, from: webView) {
            return (.cancel, preferences)
        }

        preferences.preferredContentMode = session.prefersDesktopSite(webView) ? .desktop : .recommended
        session.applyContentBlocking(to: webView, host: url.host())
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session?.pageDidFinishLoading(in: webView)
    }

    // iOS kills a web view's content process under memory pressure, which
    // leaves a blank page. Reloading brings the tab back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
