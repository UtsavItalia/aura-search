import SwiftUI

/// The site's own favicon, or the title's first letter as a fallback.
/// Icons come straight from the site you visited, never a third-party
/// favicon service, so nothing about your tabs leaks elsewhere.
struct FaviconView: View {
    let url: URL?
    let title: String
    let tint: Color
    /// `.tile` sits the icon on a tinted square, for lists. `.plain` is the
    /// bare icon. `.badge` puts it on a small white disc, as above Arc's
    /// tab cards.
    var style: Style = .tile

    init(url: URL?, title: String, tint: Color, style: Style = .tile) {
        self.url = url
        self.title = title
        self.tint = tint
        self.style = style
    }

    init(tab: BrowserTab, tint: Color, style: Style = .tile) {
        self.init(url: tab.url, title: tab.displayTitle, tint: tint, style: style)
    }

    enum Style {
        case tile
        case plain
        case badge
    }

    var body: some View {
        switch style {
        case .tile:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
                icon(size: 18, letterFont: .subheadline.weight(.semibold))
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
        case .plain:
            icon(size: 18, letterFont: .caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        case .badge:
            ZStack {
                Circle().fill(Color.white)
                icon(size: 13, letterFont: .system(size: 10, weight: .bold))
            }
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func icon(size: CGFloat, letterFont: Font) -> some View {
        if let faviconURL {
            AsyncImage(url: faviconURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                } else {
                    letter(font: letterFont)
                }
            }
        } else {
            letter(font: letterFont)
        }
    }

    @ViewBuilder
    private func letter(font: Font) -> some View {
        let text = Text(String(title.prefix(1)).uppercased())
            .font(font)
        switch style {
        case .tile, .badge:
            text.foregroundStyle(tint)
        case .plain:
            // A small tinted disc, so it reads as an icon at this size.
            text
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: Circle())
        }
    }

    private var faviconURL: URL? {
        guard let url,
              let scheme = url.scheme,
              ["http", "https"].contains(scheme),
              let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}
