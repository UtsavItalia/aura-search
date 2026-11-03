import SwiftUI
import WebKit

struct ReaderView: View {
    let article: ReaderArticle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReaderWebView(html: ReaderMode.html(for: article), baseURL: article.sourceURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(article.sourceURL?.host() ?? "Reader")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Renders the extracted article with JavaScript turned off.
private struct ReaderWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
