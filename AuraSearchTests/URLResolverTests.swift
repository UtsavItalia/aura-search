import XCTest
@testable import AuraSearch

final class URLResolverTests: XCTestCase {
    private func resolve(_ text: String) -> String? {
        URLResolver.resolve(text, engine: .duckDuckGo)?.absoluteString
    }

    func testFullURLsLoadAsTyped() {
        XCTAssertEqual(resolve("https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(resolve("http://example.com"), "http://example.com")
    }

    func testBareDomainsGetHTTPS() {
        XCTAssertEqual(resolve("example.com"), "https://example.com")
        XCTAssertEqual(resolve("en.wikipedia.org/wiki/Cat"), "https://en.wikipedia.org/wiki/Cat")
    }

    func testEverythingElseIsASearch() {
        XCTAssertEqual(resolve("swift concurrency"), "https://duckduckgo.com/?q=swift%20concurrency")
        XCTAssertEqual(resolve("pytorch"), "https://duckduckgo.com/?q=pytorch")
    }

    func testBlankInputDoesNothing() {
        XCTAssertNil(resolve("   "))
    }
}

final class SearchSuggestionsTests: XCTestCase {
    func testParsesOpenSearchFormat() {
        let json = #"["how to", ["how to vote", "How To", "  ", "how to cook", "how to vote"], [], {}]"#
        let results = SearchSuggestions.parse(Data(json.utf8), query: "how to", limit: 5)
        XCTAssertEqual(results, ["how to vote", "how to cook"], "drops the query itself, blanks and duplicates")
    }

    func testRespectsTheLimit() {
        let json = #"["a", ["a1", "a2", "a3"]]"#
        XCTAssertEqual(SearchSuggestions.parse(Data(json.utf8), query: "a", limit: 2), ["a1", "a2"])
    }

    func testBadResponsesGiveNoSuggestions() {
        XCTAssertEqual(SearchSuggestions.parse(Data("not json".utf8), query: "a", limit: 5), [])
        XCTAssertEqual(SearchSuggestions.parse(Data(#"{"a": 1}"#.utf8), query: "a", limit: 5), [])
    }

    func testEndpointUsesTheSelectedEngine() {
        let url = SearchSuggestions.endpoint(for: .duckDuckGo, query: "swift ui")
        XCTAssertEqual(url?.host(), "duckduckgo.com")
        XCTAssertEqual(url?.query(), "type=list&q=swift%20ui")
    }
}
