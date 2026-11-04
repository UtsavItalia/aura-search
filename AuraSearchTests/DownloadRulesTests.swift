import XCTest
@testable import AuraSearch

final class DownloadRulesTests: XCTestCase {
    func testAttachmentHeadersMeanSave() {
        XCTAssertTrue(DownloadRules.isAttachment("attachment"))
        XCTAssertTrue(DownloadRules.isAttachment("attachment; filename=\"photo.jpg\""))
        XCTAssertTrue(DownloadRules.isAttachment("  Attachment;filename=photo.jpg"))
        XCTAssertFalse(DownloadRules.isAttachment("inline; filename=\"report.pdf\""))
        XCTAssertFalse(DownloadRules.isAttachment("attachments"))
        XCTAssertFalse(DownloadRules.isAttachment(nil))
    }

    func testTakenNamesGetANumber() {
        XCTAssertEqual(DownloadRules.availableName(for: "photo.jpg", taken: []), "photo.jpg")
        XCTAssertEqual(DownloadRules.availableName(for: "photo.jpg", taken: ["photo.jpg"]), "photo 2.jpg")
        XCTAssertEqual(
            DownloadRules.availableName(for: "photo.jpg", taken: ["Photo.JPG", "photo 2.jpg"]),
            "photo 3.jpg",
            "names are compared ignoring case"
        )
        XCTAssertEqual(DownloadRules.availableName(for: "notes", taken: ["notes"]), "notes 2")
    }

    func testNamesAreMadeSafe() {
        XCTAssertEqual(DownloadRules.sanitized("a/b:c.txt"), "a-b-c.txt")
        XCTAssertEqual(DownloadRules.sanitized(".hidden"), "Download.hidden")
        XCTAssertEqual(DownloadRules.sanitized("   "), "Download")
        let long = String(repeating: "x", count: 300) + ".jpg"
        let short = DownloadRules.sanitized(long)
        XCTAssertLessThanOrEqual(short.utf8.count, 200)
        XCTAssertTrue(short.hasSuffix(".jpg"), "keeps the extension")
    }
}
