import XCTest
@testable import AuraSearch

@MainActor
final class TabStoreTests: XCTestCase {
    private func makeStore() -> TabStore { TabStore(fileURL: nil) }
    private var page: URL { URL(string: "https://example.com")! }

    func testNewStoreHasOneSpaceAndNoTabs() {
        let store = makeStore()
        XCTAssertEqual(store.spaces.count, 1)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
    }

    func testOpeningATabMakesItActive() {
        let store = makeStore()
        let tab = store.openTab(url: page)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertEqual(tab.spaceID, store.selectedSpaceID)
    }

    func testNavigatingKeepsTabIdentity() {
        let store = makeStore()
        let tab = store.openTab(url: page)
        store.updateTab(tab.id, url: URL(string: "https://example.com/other")!, title: "Other")
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].id, tab.id)
        XCTAssertEqual(store.tabs[0].title, "Other")
    }

    func testTheTabYouLeaveBecomesTheFrontCard() {
        let store = makeStore()
        let first = store.openTab(url: page)
        let second = store.openTab(url: page)
        let third = store.openTab(url: page)
        let space = store.selectedSpaceID

        store.moveToFront(first.id)
        XCTAssertEqual(store.tabs(in: space).map(\.id), [second.id, third.id, first.id])

        store.togglePin(third.id)
        XCTAssertEqual(store.tabs(in: space).map(\.id), [third.id, second.id, first.id], "pinned tabs stay first")
    }

    func testClosingATabArchivesIt() {
        let store = makeStore()
        let tab = store.openTab(url: page)
        store.closeTab(tab.id)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
        XCTAssertEqual(store.archive.first?.id, tab.id)
        XCTAssertEqual(store.archive.first?.reason, .closed)
    }

    func testRestoreReopensTheSameTab() {
        let store = makeStore()
        let tab = store.openTab(url: page)
        store.closeTab(tab.id)
        let restored = store.restore(tab.id)
        XCTAssertEqual(restored?.id, tab.id)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertTrue(store.archive.isEmpty)
    }

    func testStaleTabsAreArchivedExceptPinnedAndActive() {
        let store = makeStore()
        let stale = store.openTab(url: page)
        let pinned = store.openTab(url: page)
        store.togglePin(pinned.id)
        let active = store.openTab(url: page)
        XCTAssertEqual(store.activeTabID, active.id)

        let later = Date.now.addingTimeInterval(13 * 3600) // default interval is 12h
        let archived = store.archiveStaleTabs(now: later)

        XCTAssertEqual(archived, [stale.id])
        XCTAssertEqual(Set(store.tabs.map(\.id)), [pinned.id, active.id])
        XCTAssertEqual(store.archive.first?.reason, .autoArchived)
    }

    func testAutoArchiveCanBeTurnedOff() {
        let store = makeStore()
        var settings = store.settings
        settings.autoArchive = .never
        store.updateSettings(settings)
        store.openTab(url: page)
        store.showHome()
        XCTAssertTrue(store.archiveStaleTabs(now: .distantFuture).isEmpty)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testTheLastSpaceCannotBeDeleted() {
        let store = makeStore()
        XCTAssertTrue(store.deleteSpace(store.spaces[0].id).isEmpty)
        XCTAssertEqual(store.spaces.count, 1)
    }

    func testDeletingASpaceArchivesItsTabs() {
        let store = makeStore()
        let first = store.spaces[0]
        let work = store.addSpace(name: "Work", color: .blue)
        let tab = store.openTab(url: page, in: work.id)

        let closed = store.deleteSpace(work.id)

        XCTAssertEqual(closed, [tab.id])
        XCTAssertEqual(store.spaces.map(\.id), [first.id])
        XCTAssertEqual(store.selectedSpaceID, first.id)
        XCTAssertEqual(store.archive.first?.id, tab.id)
    }

    func testStateSurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TabStore(fileURL: url)
        let work = store.addSpace(name: "Work", color: .green)
        let tab = store.openTab(url: page, in: work.id)
        store.togglePin(tab.id)
        store.saveNow()

        let relaunched = TabStore(fileURL: url)
        XCTAssertEqual(relaunched.spaces.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(relaunched.tabs.first?.id, tab.id)
        XCTAssertEqual(relaunched.tabs.first?.isPinned, true)
        XCTAssertEqual(relaunched.activeTabID, tab.id, "reopens on the last tab you viewed")
        XCTAssertEqual(relaunched.selectedSpaceID, work.id)
    }

    func testLastTabIsRestoredEvenAfterGoingHome() throws {
        let url = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TabStore(fileURL: url)
        let tab = store.openTab(url: page)
        store.showHome()
        store.saveNow()

        XCTAssertEqual(TabStore(fileURL: url).activeTabID, tab.id)
    }

    func testClosedLastTabIsNotRestored() throws {
        let url = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TabStore(fileURL: url)
        let tab = store.openTab(url: page)
        store.closeTab(tab.id)
        store.saveNow()

        XCTAssertNil(TabStore(fileURL: url).activeTabID)
    }

    func testPrivateTabsAreNeverSavedOrArchived() throws {
        let url = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TabStore(fileURL: url)
        let normal = store.openTab(url: page)
        let secret = store.openTab(url: page, isPrivate: true)
        XCTAssertTrue(secret.isPrivate)
        store.saveNow()

        let relaunched = TabStore(fileURL: url)
        XCTAssertEqual(relaunched.tabs.map(\.id), [normal.id], "private tabs don't survive a relaunch")
        XCTAssertEqual(relaunched.activeTabID, normal.id, "a private tab is never the one reopened")

        store.closeTab(secret.id)
        XCTAssertFalse(store.archive.contains { $0.id == secret.id }, "private tabs leave no archive entry")
    }

    func testChangesAreSavedShortlyWithoutBeingAsked() async throws {
        let url = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TabStore(fileURL: url)
        let tab = store.openTab(url: page)

        // Saves batch up for half a second, then write off the main thread.
        var saved: [UUID] = []
        for _ in 0..<40 {
            saved = TabStore(fileURL: url).tabs.map(\.id)
            if saved == [tab.id] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(saved, [tab.id], "saved within a moment, with no saveNow()")
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
    }
}
