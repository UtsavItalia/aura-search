import XCTest
@testable import AuraSearch

final class SummaryTextTests: XCTestCase {
    func testTidiesPageText() {
        let messy = "  Title  \n\n\n\n  First   line\t here \n\n\nSecond\u{00A0}line  \n\n"
        XCTAssertEqual(SummaryText.normalized(messy), "Title\n\nFirst line here\n\nSecond line")
    }

    func testShortTextIsOneChunk() {
        XCTAssertEqual(SummaryText.chunks(of: "Just a little text.", limit: 1_000), ["Just a little text."])
        XCTAssertEqual(SummaryText.chunks(of: "  \n ", limit: 1_000), [])
    }

    func testLongTextSplitsWithinTheLimitAndKeepsEveryWord() {
        let paragraph = (1...40).map { "Sentence number \($0) has a few words in it." }.joined(separator: " ")
        let text = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
        let chunks = SummaryText.chunks(of: text, limit: 900)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 900 }, "every chunk fits")
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace).map(String.init) }
        XCTAssertEqual(chunks.flatMap(words), words(text), "nothing lost or reordered")
    }

    func testTextWithoutSpacesIsCutToFit() {
        let text = String(repeating: "字", count: 2_500)
        XCTAssertEqual(SummaryText.chunks(of: text, limit: 1_000).map(\.count), [1_000, 1_000, 500])
    }

    func testReadsTheOpeningSentenceAndBullets() {
        let outline = SummaryText.parse("""
        **The city approved a new bike network.**
        - 40 km of protected lanes by 2028
        • Funded by a parking levy
        2. Construction starts in spring
        """)
        XCTAssertEqual(outline.headline, "The city approved a new bike network.")
        XCTAssertEqual(outline.bullets, [
            "40 km of protected lanes by 2028",
            "Funded by a parking levy",
            "Construction starts in spring",
        ])
    }

    func testHalfWrittenBulletIsntShownYet() {
        let outline = SummaryText.parse("Summary: Rain is coming.\n-")
        XCTAssertEqual(outline.headline, "Rain is coming.")
        XCTAssertEqual(outline.bullets, [])
    }

    func testCopiedTextReadsWell() {
        let outline = SummaryOutline(headline: "Rain is coming.", bullets: ["Take a coat", "Roads may flood"])
        XCTAssertEqual(
            SummaryText.plainText(outline, url: URL(string: "https://example.com/weather")),
            "Rain is coming.\n\n• Take a coat\n• Roads may flood\n\nhttps://example.com/weather"
        )
    }

    func testEstimatesTokensByScript() {
        XCTAssertEqual(SummaryText.charactersPerToken(for: "The quick brown fox jumps over the lazy dog."), 3)
        XCTAssertEqual(SummaryText.charactersPerToken(for: "東京は日本の首都です。人口がとても多いです。"), 1)
        XCTAssertEqual(SummaryText.charactersPerToken(for: "Москва — столица России."), 2)
    }

    func testLongNotesAreTrimmedToFit() {
        let notes = Array(repeating: String(repeating: "n", count: 1_000), count: 4)
        XCTAssertLessThanOrEqual(SummaryText.fitted(notes, limit: 2_000).count, 2_000)
        XCTAssertEqual(SummaryText.fitted(["a", "b"], limit: 2_000), "a\n\nb")
    }

    /// iOS 26 and iOS 27 name these errors differently, so they're matched by name.
    func testRecognizesModelErrorsByName() {
        enum FakeModelError: Error {
            case exceededContextWindowSize(String)
            case contextSizeExceeded
            case unsupportedLanguageOrLocale
            case guardrailViolation
            case rateLimited
            case somethingElse
        }
        XCTAssertEqual(SummaryText.failure(for: FakeModelError.exceededContextWindowSize("4096")), .tooLong)
        XCTAssertEqual(SummaryText.failure(for: FakeModelError.contextSizeExceeded), .tooLong)
        XCTAssertEqual(SummaryText.failure(for: FakeModelError.unsupportedLanguageOrLocale), .unsupportedLanguage)
        XCTAssertEqual(SummaryText.failure(for: FakeModelError.guardrailViolation), .sensitive)
        XCTAssertEqual(SummaryText.failure(for: FakeModelError.rateLimited), .busy)
        XCTAssertEqual(SummaryText.failure(for: FakeModelError.somethingElse), .other)
    }
}
