import UIKit
import WebKit

/// Arc's pinch to summarize: pinching a page in past its smallest zoom asks
/// for a summary. Ordinary zooming in and out works as before; only the
/// extra pinch once the page can't get any smaller counts.
@MainActor
final class PinchToSummarize: NSObject, UIGestureRecognizerDelegate {
    /// Returns whether a summary opened, which is when the pinch is felt.
    private let onPinch: () -> Bool
    private weak var scrollView: UIScrollView?
    /// The pinch's scale when the page reached its smallest zoom.
    private var scaleAtSmallest: CGFloat?
    private var hasFired = false

    /// How much further than the smallest zoom to pinch: to 70% of it.
    private static let threshold: CGFloat = 0.7

    init(webView: WKWebView, onPinch: @escaping () -> Bool) {
        self.onPinch = onPinch
        self.scrollView = webView.scrollView
        super.init()
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        recognizer.delegate = self
        // Watches alongside the page's own gestures, never instead of them.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        webView.addGestureRecognizer(recognizer)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            scaleAtSmallest = nil
            hasFired = false
        case .changed:
            guard !hasFired, let scrollView else { return }
            // While pinching, the zoom can dip just under its minimum before
            // bouncing back, so a little leeway.
            let atSmallest = scrollView.zoomScale <= scrollView.minimumZoomScale * 1.02
            if atSmallest, scaleAtSmallest == nil {
                scaleAtSmallest = recognizer.scale
            }
            if let start = scaleAtSmallest, recognizer.scale < start * Self.threshold {
                hasFired = true
                if onPinch() {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        default:
            scaleAtSmallest = nil
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
