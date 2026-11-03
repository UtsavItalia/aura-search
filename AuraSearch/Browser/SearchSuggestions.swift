import Foundation

/// Search-as-you-type suggestions from the selected search engine.
///
/// Every engine here serves the OpenSearch suggestion format browsers use:
/// `["query", ["suggestion 1", "suggestion 2", ...]]`. Requests go through an
/// ephemeral session with cookies off, so they don't carry anything that
/// links them to you beyond the text itself.
enum SearchSuggestions {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    static func endpoint(for engine: SearchEngine, query: String) -> URL? {
        let base: String
        var items: [URLQueryItem]
        switch engine {
        case .duckDuckGo:
            base = "https://duckduckgo.com/ac/"
            items = [URLQueryItem(name: "type", value: "list"), URLQueryItem(name: "q", value: query)]
        case .google:
            base = "https://suggestqueries.google.com/complete/search"
            items = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "oe", value: "utf-8"),
                URLQueryItem(name: "q", value: query),
            ]
        case .bing:
            base = "https://www.bing.com/osjson.aspx"
            items = [URLQueryItem(name: "query", value: query)]
        case .brave:
            base = "https://search.brave.com/api/suggest"
            items = [URLQueryItem(name: "q", value: query)]
        case .startpage:
            base = "https://www.startpage.com/osuggestions"
            items = [URLQueryItem(name: "q", value: query)]
        }
        var components = URLComponents(string: base)
        components?.queryItems = items
        return components?.url
    }

    /// Suggestions for the text, or an empty list on any failure: a missing
    /// suggestion list should never get in the way of searching.
    static func fetch(for query: String, engine: SearchEngine, limit: Int = 5) async -> [String] {
        guard let url = endpoint(for: engine, query: query) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return parse(data, query: query, limit: limit)
        } catch {
            return []
        }
    }

    /// Reads the OpenSearch format, dropping blanks, duplicates and the query itself.
    static func parse(_ data: Data, query: String, limit: Int) -> [String] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              array.count > 1,
              let items = array[1] as? [String] else { return [] }

        var seen: Set<String> = [query.trimmingCharacters(in: .whitespaces).lowercased()]
        var results: [String] = []
        for item in items {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            results.append(text)
            if results.count == limit { break }
        }
        return results
    }
}
