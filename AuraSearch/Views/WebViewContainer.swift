import SwiftUI
import WebKit

/// Hosts a tab's existing web view. The web views live in `BrowserSession`,
/// not here, so switching tabs swaps views instead of reloading pages.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    /// How much of the page's bottom the bar covers.
    var bottomInset: CGFloat = 0
    /// False while the web view is kept out of the window, as it is while
    /// a card grows into its page (`BrowserSession.holdBack`). The empty
    /// container is under the page's cover then.
    var isAttached = true

    final class Coordinator {
        var bottomConstraint: NSLayoutConstraint?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard isAttached else { return }
        if webView.superview !== container {
            for subview in container.subviews { subview.removeFromSuperview() }
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            let bottom = webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                bottom,
            ])
            context.coordinator.bottomConstraint = bottom
        }

        // The page's frame already starts below the status bar, so insets are
        // set here rather than worked out by UIKit.
        let scrollView = webView.scrollView
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        // The page runs under the bottom bar, as in Arc. WebKit has to be told
        // the bar covers it, or anything a page pins to the bottom of the
        // screen (cookie banners and their buttons, chat buttons) sits hidden
        // behind the bar: WebKit ignores scroll insets when it places those.
        // iOS 26 lets apps say so. Before that, the page stops at the bar.
        let marksBarAsCovering = Self.canMarkBarAsCovering
        let scrollInset = marksBarAsCovering ? bottomInset : 0
        if scrollView.contentInset.bottom != scrollInset {
            scrollView.contentInset.bottom = scrollInset
            scrollView.verticalScrollIndicatorInsets.bottom = scrollInset
        }
        let frameInset = marksBarAsCovering ? 0 : bottomInset
        if let bottom = context.coordinator.bottomConstraint, bottom.constant != -frameInset {
            bottom.constant = -frameInset
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let covered = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
            if webView.obscuredContentInsets != covered {
                webView.obscuredContentInsets = covered
            }
        }
        #endif
    }

    /// Whether WebKit can be told about the bar (iOS 26 and later, built
    /// with Xcode 26 or later).
    private static var canMarkBarAsCovering: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}
