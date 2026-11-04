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

/// The round buttons at the ends of the bottom bar, sized like Arc's:
/// a 34pt circle inside a bigger tap area.
struct BarCircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: BarMetrics.circle, height: BarMetrics.circle)
                .background(Color.primary.opacity(0.07), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(width: BarMetrics.tapSize, height: BarMetrics.tapSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

/// The "+" capsule in the middle of the bottom bar.
struct BarPlusButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .frame(width: BarMetrics.capsuleWidth, height: BarMetrics.height)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("New tab")
    }
}

/// The tabs button under a page: your latest tabs as a tiny fanned
/// stack, as in Arc. An icon until there's a page to show.
struct TabStackButton: View {
    /// Back to front: the tab before this one, then this one.
    let images: [UIImage]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if images.isEmpty {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: BarMetrics.circle, height: BarMetrics.circle)
                        .background(Color.primary.opacity(0.07), in: Circle())
                } else {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        let isFront = index == images.count - 1
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 19, height: 29, alignment: .top)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                            .rotationEffect(.degrees(isFront ? 9 : -13))
                            .offset(x: isFront ? 4 : -4, y: isFront ? 1 : 0)
                    }
                }
            }
            .frame(width: BarMetrics.tapSize, height: BarMetrics.tapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("Tabs")
    }
}
