import Foundation

/// Turns whatever was typed in the address bar into a URL to load:
/// a full URL, a bare domain, or a search query.
enum URLResolver {
    static func resolve(_ input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already a full web URL.
        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host() != nil {
            return url
        }

        // Looks like a bare domain ("example.com", "en.wikipedia.org/wiki/Cat").
        if !text.contains(" "),
           text.contains("."),
           let url = URL(string: "https://" + text),
           let host = url.host(),
           host.contains("."),
           !host.hasPrefix("."),
           !host.hasSuffix(".") {
            return url
        }

        return engine.searchURL(for: text)
    }
}
