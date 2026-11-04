import SwiftUI
import WebKit

/// Hosts a tab's existing web view. The web views live in `BrowserSession`,
/// not here, so switching tabs swaps views instead of reloading pages.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    /// The page runs under the bottom bar; this lets it scroll its last
    /// stretch up above the bar.
    var bottomInset: CGFloat = 0

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container {
            for subview in container.subviews { subview.removeFromSuperview() }
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // The page's frame already starts below the status bar, so insets are
        // set here rather than worked out by UIKit.
        let scrollView = webView.scrollView
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        if scrollView.contentInset.bottom != bottomInset {
            scrollView.contentInset.bottom = bottomInset
            scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
    }
}
