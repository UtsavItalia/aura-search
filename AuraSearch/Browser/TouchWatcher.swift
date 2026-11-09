import UIKit

/// Tells when a finger lands on a view, without taking the touch from it.
///
/// Used to lift a page's picture the moment you touch the page under it:
/// the touch goes to the real page, so that's what should be showing.
@MainActor
final class TouchWatcher: NSObject, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(view: UIView, onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init()
        // A press with no minimum duration begins as soon as a finger lands.
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(touched(_:)))
        recognizer.minimumPressDuration = 0
        recognizer.delegate = self
        // Watches alongside the page's own gestures, never instead of them.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        view.addGestureRecognizer(recognizer)
    }

    @objc private func touched(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onTouch() }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
