import XCTest
@testable import AuraSearch

/// The deck's resting layouts, checked against positions measured from Arc
/// Search on a 440 × 956pt iPhone.
final class DeckLayoutTests: XCTestCase {
    private let phone = ScreenMetrics(width: 440, height: 956, safeTop: 62, safeBottom: 34)

    private func lefts(at position: CGFloat, count: Int) -> [CGFloat] {
        (0..<count).map { (DeckLayout.x(CGFloat($0) - position) * 440).rounded() }
    }

    func testCardsAreThePageAtSeventyPercent() {
        let size = DeckLayout.cardSize(in: phone)
        XCTAssertEqual(size.width, 308, accuracy: 1)
        XCTAssertEqual(size.height, 626, accuracy: 1)
        XCTAssertEqual(DeckLayout.cardTop(in: phone), 179, accuracy: 1)
    }

    func testRestingPositionsShiftAtTheEnds() {
        let one = DeckLayout.restPositions(count: 1)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0], 0.31, accuracy: 0.0001)
        let three = DeckLayout.restPositions(count: 3)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three[0], 0.31, accuracy: 0.0001)
        XCTAssertEqual(three[1], 1, accuracy: 0.0001)
        XCTAssertEqual(three[2], 2.31, accuracy: 0.0001)
    }

    func testMiddleCardInFront() {
        // Previous tab a sliver at the left, front card, next card overlapping.
        XCTAssertEqual(lefts(at: 1, count: 3), [13, 90, 332])
    }

    func testFirstCardInFront() {
        let x = lefts(at: DeckLayout.restPosition(for: 0, count: 3), count: 2)
        XCTAssertEqual(x[0], 66, accuracy: 1)
        XCTAssertEqual(x[1], 276, accuracy: 1)
    }

    func testLastCardInFront() {
        let x = lefts(at: DeckLayout.restPosition(for: 2, count: 3), count: 3)
        XCTAssertEqual(x[2], 66, accuracy: 1)
        XCTAssertEqual(x[1], 9, accuracy: 1)
    }

    func testOpeningFromAPageShowsItPeekingFromTheRight() {
        // On the third of three tabs: the second is in front, the third peeks in.
        let position = DeckLayout.openingPosition(currentIndex: 2, count: 3)
        XCTAssertEqual(position, 1, accuracy: 0.0001)
        XCTAssertEqual(DeckLayout.previewRect(u: 2 - position, in: phone).minX, 332, accuracy: 1)
    }

    func testCardsBehindAreDimmedAndFrontCardIsNot() {
        XCTAssertEqual(DeckLayout.dim(0), 0, accuracy: 0.0001)
        XCTAssertEqual(DeckLayout.dim(-0.31), 0, accuracy: 0.0001)
        XCTAssertEqual(DeckLayout.dim(-1), 0.224, accuracy: 0.001)
    }

    func testFlicksSnapToANearbyRestingPosition() {
        XCTAssertEqual(DeckLayout.nearestRest(to: 0.9, from: 0.31, count: 3), 1, accuracy: 0.0001)
        XCTAssertEqual(DeckLayout.nearestRest(to: 9, from: 0.31, count: 5), 2, accuracy: 0.0001, "at most two cards per flick")
        XCTAssertEqual(DeckLayout.nearestRest(to: -3, from: 1, count: 3), 0.31, accuracy: 0.0001)
    }
}
