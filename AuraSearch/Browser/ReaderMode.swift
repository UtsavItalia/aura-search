import WebKit

struct ReaderArticle: Identifiable {
    let id = UUID()
    let title: String
    let byline: String
    let contentHTML: String
    let sourceURL: URL?
}

private struct ReadabilityPayload: Decodable {
    let title: String
    let byline: String
    let content: String
}

/// Reader mode, using Mozilla's Readability.js (the library behind
/// Firefox's reader view). It runs in an isolated JavaScript world, so the
/// page's own scripts can't see or tamper with it.
@MainActor
enum ReaderMode {
    private static let readabilitySource: String? = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// False if Readability.js wasn't bundled (run scripts/bootstrap.sh).
    static var isAvailable: Bool { readabilitySource != nil }

    private static let extractionScript = """
    ;(function () {
      try {
        var article = new Readability(document.cloneNode(true)).parse();
        if (!article || !article.content) { return ""; }
        return JSON.stringify({
          title: article.title || "",
          byline: article.byline || "",
          content: article.content
        });
      } catch (e) {
        return "";
      }
    })();
    """

    /// Extracts the main article from the page, or `nil` if the page
    /// isn't an article (search results, apps, video pages...).
    static func extract(from webView: WKWebView) async -> ReaderArticle? {
        guard let source = readabilitySource else { return nil }
        let script = source + "\n" + extractionScript

        let json: String = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? String ?? "")
                case .failure:
                    continuation.resume(returning: "")
                }
            }
        }

        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReadabilityPayload.self, from: data),
              !payload.content.isEmpty else { return nil }

        return ReaderArticle(
            title: payload.title.isEmpty ? (webView.title ?? "") : payload.title,
            byline: payload.byline,
            contentHTML: payload.content,
            sourceURL: webView.url
        )
    }

    /// The reader page. Shown with JavaScript off and a strict content
    /// security policy, so only text, images and media get through.
    static func html(for article: ReaderArticle) -> String {
        let byline = article.byline.isEmpty ? "" : "<p class=\"byline\">\(escape(article.byline))</p>"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'">
        <style>\(css)</style>
        </head>
        <body>
        <article>
        <h1>\(escape(article.title))</h1>
        \(byline)
        \(article.contentHTML)
        </article>
        </body>
        </html>
        """
    }

    private static let css = """
    :root { color-scheme: light dark; }
    body {
      font: -apple-system-body;
      font-family: ui-serif, Georgia, serif;
      line-height: 1.6;
      margin: 0;
      padding: 24px 20px 64px;
    }
    article { max-width: 680px; margin: 0 auto; }
    h1 { font-family: -apple-system, sans-serif; font-size: 1.6em; line-height: 1.25; margin: 0 0 0.4em; }
    .byline { color: gray; margin-top: 0; font-family: -apple-system, sans-serif; }
    img, video, figure { max-width: 100%; height: auto; }
    figure { margin: 1.2em 0; }
    pre { overflow-x: auto; }
    a { color: #7c5cf4; }
    @media (prefers-color-scheme: dark) { a { color: #a38eff; } }
    """

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
