import XCTest
@testable import AuraSearch

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testRepeatVisitsAddUpInOneEntry() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://example.com/a"), title: "A")
        history.recordVisit(url: url("https://example.com/a#section"), title: "A again")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].visitCount, 2)
        XCTAssertEqual(history.entries[0].title, "A again")
    }

    func testSearchResultPagesAreNotRecorded() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://duckduckgo.com/?q=swift"), title: nil)
        history.recordVisit(url: url("https://www.google.com/search?q=swift"), title: nil)
        history.recordVisit(url: url("https://www.google.com/"), title: "Google")
        XCTAssertEqual(history.entries.map(\.displayURL), ["google.com"])
    }

    func testCompletesToTheSiteFirst() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://www.google.com/maps/place/x"), title: nil)
        XCTAssertEqual(history.completion(for: "goo"), "google.com")
        XCTAssertEqual(history.completion(for: "www.goo"), "www.google.com")
        XCTAssertNil(history.completion(for: "google.com"), "nothing left to add")
        XCTAssertNil(history.completion(for: "goo gle"), "spaces mean a search")
    }

    func testCompletesPathsAfterASlash() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://github.com/apple/swift"), title: nil)
        XCTAssertEqual(history.completion(for: "github.com/ap"), "github.com/apple/swift")
    }

    func testThePopularSiteWins() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://gitlab.com/"), title: nil)
        for _ in 0..<3 { history.recordVisit(url: url("https://github.com/"), title: nil) }
        XCTAssertEqual(history.completion(for: "git"), "github.com")
    }

    func testTypedAddressesRankHigher() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://gitlab.com/"), title: nil)
        history.recordVisit(url: url("https://gitlab.com/"), title: nil)
        history.recordVisit(url: url("https://github.com/"), title: nil)
        history.recordTyped(url("https://github.com/"))
        XCTAssertEqual(history.completion(for: "git"), "github.com")
    }

    func testOldVisitsFade() {
        let history = HistoryStore(fileURL: nil)
        let now = Date.now
        for _ in 0..<4 {
            history.recordVisit(url: url("https://old.example.org/"), title: nil, at: now.addingTimeInterval(-90 * 86_400))
        }
        history.recordVisit(url: url("https://one.example.org/"), title: nil, at: now)
        let top = history.matches(for: "example", limit: 2, now: now).first
        XCTAssertEqual(top?.displayURL, "one.example.org")
    }

    func testMatchesSkipOpenTabsAndUnvisitedTypedEntries() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(url: url("https://swift.org/"), title: "Swift")
        history.recordVisit(url: url("https://swiftui.dev/"), title: "SwiftUI")
        history.recordTyped(url("https://swiftly.example/"))
        let open: Set<String> = [HistoryStore.key(for: url("https://swift.org/"))]
        XCTAssertEqual(history.matches(for: "swift", limit: 5, excluding: open).map(\.displayURL), ["swiftui.dev"])
    }

    func testHistorySurvivesARelaunch() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let history = HistoryStore(fileURL: file)
        history.recordVisit(url: url("https://example.com/"), title: "Example")
        history.saveNow()

        XCTAssertEqual(HistoryStore(fileURL: file).entries.first?.title, "Example")
    }
}
