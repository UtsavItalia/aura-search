import SwiftUI

/// The soft pastel wash behind the tab cards, like Arc Search's: a light
/// tint of the Space's color at the top, warming to pink on the right.
/// In dark mode the same colors sit on a deep base instead of white.
struct PastelBackground: View {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack {
            isDark ? Color(white: 0.07) : Color.white
            LinearGradient(
                colors: [tint.opacity(isDark ? 0.30 : 0.20), tint.opacity(isDark ? 0.14 : 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.pink.opacity(isDark ? 0.16 : 0.13), Color.pink.opacity(0)],
                center: UnitPoint(x: 1.05, y: 0.55),
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [tint.opacity(isDark ? 0.10 : 0.08), tint.opacity(0)],
                center: UnitPoint(x: 0, y: 0.9),
                startRadius: 0,
                endRadius: 360
            )
        }
    }
}

extension View {
    /// The bar under a page: the system bar normally, and a solid charcoal
    /// strip with light icons on private tabs, as in Arc Search.
    func browserBar(isPrivate: Bool) -> some View {
        modifier(BrowserBar(isPrivate: isPrivate))
    }
}

private struct BrowserBar: ViewModifier {
    let isPrivate: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPrivate {
            content
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
                .background {
                    Color(red: 0.18, green: 0.18, blue: 0.20)
                        .ignoresSafeArea(edges: .bottom)
                }
        } else {
            content
                .foregroundStyle(.primary)
                .background(.bar, ignoresSafeAreaEdges: .bottom)
        }
    }
}
