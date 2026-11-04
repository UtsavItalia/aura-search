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
            session?.openTabFromPage(url, openedBy: webView)
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

        // Links marked for saving, like <a download>.
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        Self.shouldDownload(navigationResponse) ? .download : .allow
    }

    /// Saves files the server marks as attachments, which is how most
    /// Download buttons work (Unsplash's included), and files a page can't
    /// show, like zips. Anything else opens as usual, PDFs and images too.
    private static func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
        if let http = navigationResponse.response as? HTTPURLResponse {
            // Nothing to save from an error page or an empty reply.
            guard (200..<300).contains(http.statusCode),
                  http.statusCode != 204, http.statusCode != 205 else { return false }
            if DownloadRules.isAttachment(http.value(forHTTPHeaderField: "Content-Disposition")) {
                return true
            }
        }
        // A frame inside a page that can't show its file is just left empty.
        return navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        session?.downloads.track(download)
        session?.downloadStarted(in: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        session?.downloads.track(download)
        session?.downloadStarted(in: webView)
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
