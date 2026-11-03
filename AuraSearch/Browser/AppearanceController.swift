import UIKit

/// Applies the Appearance setting. System leaves light and dark mode to iOS;
/// Light or Dark overrides it for the app's windows, web pages included.
@MainActor
enum AppearanceController {
    static func apply(_ appearance: AppAppearance) {
        let style: UIUserInterfaceStyle
        switch appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
