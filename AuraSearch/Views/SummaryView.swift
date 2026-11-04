import SwiftUI
import UIKit

/// A summary of the page, written on the iPhone by Apple Intelligence, like
/// Arc's pinch to summarize. Opens from the page menu, or by pinching the
/// page in past its smallest zoom.
struct SummaryView: View {
    let tab: BrowserTab

    @Environment(BrowserSession.self) private var session
    @State private var summary = PageSummary()
    /// Bumped by Try Again, which runs the summary again.
    @State private var attempt = 0
    @State private var justCopied = false

    /// The halo colors from the app icon.
    private static let aura = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.60, blue: 0.42),
            Color(red: 1.0, green: 0.37, blue: 0.54),
            Color(red: 0.65, green: 0.42, blue: 1.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        let outline = SummaryText.parse(summary.text)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(outline)
                content(outline)
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(32)
        .sensoryFeedback(.success, trigger: justCopied) { _, copied in copied }
        .task(id: attempt) {
            await summary.run(on: session.activeWebView)
        }
    }

    // MARK: - Header

    private func header(_ outline: SummaryOutline) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Self.aura)
                .symbolEffect(.pulse, isActive: summary.isWorking)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Summary")
                    .font(.headline)
                Text(tab.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if summary.phase == .done {
                Button {
                    copy(outline)
                } label: {
                    circleIcon(justCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy summary")

                ShareLink(item: SummaryText.plainText(outline, url: tab.url)) {
                    circleIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share summary")
            }
        }
    }

    private func circleIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 36, height: 36)
            .background(Color.primary.opacity(0.08), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ outline: SummaryOutline) -> some View {
        switch summary.phase {
        case .reading, .readingPart:
            VStack(alignment: .leading, spacing: 16) {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.quick, value: status)
                PlaceholderLines()
            }
        case .writing, .done:
            SummaryBody(outline: outline)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
    }

    private var status: String {
        if case .readingPart(let part, of: let total) = summary.phase {
            return "Reading part \(part) of \(total)…"
        }
        return "Reading the page…"
    }

    @ViewBuilder
    private var footer: some View {
        if summary.phase == .writing || summary.phase == .done {
            VStack(alignment: .leading, spacing: 6) {
                if summary.isPartial {
                    Text("This page is very long, so only its first part was summarized.")
                }
                Text("Written on this iPhone by Apple Intelligence. It can make mistakes, so check anything important on the page.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ outline: SummaryOutline) {
        UIPasteboard.general.string = SummaryText.plainText(outline, url: tab.url)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }
}

/// The opening sentence, then the bullet points, appearing as they're written.
private struct SummaryBody: View {
    let outline: SummaryOutline

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !outline.headline.isEmpty {
                Text(outline.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(outline.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(bullet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .textSelection(.enabled)
        .animation(Motion.fade, value: outline.bullets.count)
    }
}

/// Soft lines standing in for the summary while the page is read.
private struct PlaceholderLines: View {
    @State private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            line(trailing: 0)
            line(trailing: 28)
            line(trailing: 8)
            line(trailing: 120)
        }
        .opacity(dimmed ? 0.4 : 1)
        .animation(Motion.pulse, value: dimmed)
        .onAppear { dimmed = true }
        .accessibilityHidden(true)
    }

    private func line(trailing: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 12)
            .padding(.trailing, trailing)
    }
}
