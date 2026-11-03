import Foundation
import Observation

/// The app's data: Spaces, open tabs, the archive and settings.
///
/// This type knows nothing about web views; `BrowserSession` owns those.
/// Keeping them apart means the data can be tested, saved and (later)
/// synced without a live browser.
@MainActor
@Observable
final class TabStore {
    private(set) var spaces: [Space]
    private(set) var tabs: [BrowserTab]
    private(set) var archive: [ArchivedTab]
    private(set) var selectedSpaceID: UUID
    /// The tab on screen. `nil` means the home screen (tab cards).
    private(set) var activeTabID: UUID?
    /// The last tab you looked at, reopened at launch like Arc Search.
    /// Unlike `activeTabID`, going to the home screen doesn't clear it.
    private(set) var lastViewedTabID: UUID?
    private(set) var settings: BrowserSettings

    /// How many archived tabs to keep before dropping the oldest.
    static let archiveLimit = 200

    private let fileURL: URL?

    /// - Parameter fileURL: where state is saved. Pass `nil` for an
    ///   in-memory store (used by tests and previews).
    init(fileURL: URL? = TabStore.defaultFileURL) {
        self.fileURL = fileURL

        let state: Snapshot
        if let saved = fileURL.flatMap({ Self.load(from: $0) }), !saved.spaces.isEmpty {
            state = saved
        } else {
            let personal = Space(name: "Personal", color: .violet)
            state = Snapshot(
                spaces: [personal],
                tabs: [],
                archive: [],
                selectedSpaceID: personal.id,
                settings: BrowserSettings(),
                lastViewedTabID: nil
            )
        }

        var selected = state.spaces.contains(where: { $0.id == state.selectedSpaceID })
            ? state.selectedSpaceID
            : state.spaces[0].id

        // Reopen the last tab you were on, unless it's old enough to be archived.
        var restored: UUID?
        if let lastID = state.lastViewedTabID,
           let tab = state.tabs.first(where: { $0.id == lastID }),
           !Self.isStale(tab, settings: state.settings, now: .now) {
            restored = lastID
            selected = tab.spaceID
        }

        spaces = state.spaces
        tabs = state.tabs
        archive = state.archive
        settings = state.settings
        selectedSpaceID = selected
        activeTabID = restored
        lastViewedTabID = restored
    }

    private static func isStale(_ tab: BrowserTab, settings: BrowserSettings, now: Date) -> Bool {
        guard !tab.isPinned, let interval = settings.autoArchive.seconds else { return false }
        return now.timeIntervalSince(tab.lastActiveAt) > interval
    }

    // MARK: - Reading

    var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var selectedSpace: Space {
        spaces.first { $0.id == selectedSpaceID } ?? spaces[0]
    }

    func space(withID id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    /// Tabs in a Space, in carousel order: pinned first, then oldest to
    /// newest, so a new tab joins the end of the deck like Arc Search.
    func tabs(in spaceID: UUID) -> [BrowserTab] {
        tabs
            .filter { $0.spaceID == spaceID }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.createdAt < rhs.createdAt
            }
    }

    // MARK: - Tabs

    @discardableResult
    func openTab(url: URL?, in spaceID: UUID? = nil, isPrivate: Bool = false) -> BrowserTab {
        let tab = BrowserTab(spaceID: spaceID ?? selectedSpaceID, url: url, isPrivate: isPrivate)
        tabs.append(tab)
        setActive(tab)
        persist()
        return tab
    }

    func activate(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].lastActiveAt = .now
        setActive(tabs[index])
        persist()
    }

    private func setActive(_ tab: BrowserTab) {
        activeTabID = tab.id
        selectedSpaceID = tab.spaceID
        // Private tabs aren't saved, so they can't be reopened at launch.
        if !tab.isPrivate { lastViewedTabID = tab.id }
    }

    /// Back to the home screen. The tab stays open.
    func showHome() {
        if let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs[index].lastActiveAt = .now
            persist()
        }
        activeTabID = nil
    }

    /// Called when the page in a tab navigates or changes its title.
    func updateTab(_ id: UUID, url: URL?, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        if let url { tab.url = url }
        if let title { tab.title = title }
        guard tab != tabs[index] else { return }
        tabs[index] = tab
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()
        persist()
    }

    func moveTab(_ id: UUID, to spaceID: UUID) {
        guard space(withID: spaceID) != nil,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].spaceID = spaceID
        persist()
    }

    /// Closes a tab and keeps it in the archive.
    func closeTab(_ id: UUID) {
        closeTabs([id], reason: .closed)
    }

    /// Closes every unpinned tab in a Space. Returns the closed tab IDs.
    @discardableResult
    func closeUnpinnedTabs(in spaceID: UUID) -> [UUID] {
        let ids = tabs.filter { $0.spaceID == spaceID && !$0.isPinned }.map(\.id)
        closeTabs(ids, reason: .closed)
        return ids
    }

    /// Moves tabs that haven't been used for the auto-archive interval into
    /// the archive. Pinned tabs and the tab on screen are never touched.
    /// Returns the archived tab IDs.
    @discardableResult
    func archiveStaleTabs(now: Date = .now) -> [UUID] {
        guard let interval = settings.autoArchive.seconds else { return [] }
        let ids = tabs
            .filter { !$0.isPinned && $0.id != activeTabID && now.timeIntervalSince($0.lastActiveAt) > interval }
            .map(\.id)
        closeTabs(ids, reason: .autoArchived, now: now)
        return ids
    }

    private func closeTabs(_ ids: [UUID], reason: ArchivedTab.Reason, now: Date = .now) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let closing = tabs.filter { idSet.contains($0.id) }
        tabs.removeAll { idSet.contains($0.id) }
        // Restorable tabs only make sense if they had a page loaded, and
        // private tabs leave no trace.
        let archived = closing
            .filter { $0.url != nil && !$0.isPrivate }
            .map { ArchivedTab(tab: $0, archivedAt: now, reason: reason) }
        archive.insert(contentsOf: archived, at: 0)
        if archive.count > Self.archiveLimit {
            archive.removeLast(archive.count - Self.archiveLimit)
        }
        if let activeTabID, idSet.contains(activeTabID) {
            self.activeTabID = nil
        }
        if let lastViewedTabID, idSet.contains(lastViewedTabID) {
            self.lastViewedTabID = nil
        }
        persist()
    }

    // MARK: - Archive

    /// Reopens an archived tab (into its old Space if it still exists)
    /// and puts it on screen.
    @discardableResult
    func restore(_ archivedID: UUID) -> BrowserTab? {
        guard let index = archive.firstIndex(where: { $0.id == archivedID }) else { return nil }
        var tab = archive.remove(at: index).tab
        if space(withID: tab.spaceID) == nil { tab.spaceID = selectedSpaceID }
        tab.lastActiveAt = .now
        tabs.append(tab)
        setActive(tab)
        persist()
        return tab
    }

    func clearArchive() {
        archive.removeAll()
        persist()
    }

    // MARK: - Spaces

    func selectSpace(_ id: UUID) {
        guard space(withID: id) != nil, id != selectedSpaceID else { return }
        selectedSpaceID = id
        persist()
    }

    @discardableResult
    func addSpace(name: String, color: SpaceColor) -> Space {
        let space = Space(name: Self.cleanName(name), color: color)
        spaces.append(space)
        selectedSpaceID = space.id
        persist()
        return space
    }

    func updateSpace(_ id: UUID, name: String, color: SpaceColor) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = Self.cleanName(name)
        spaces[index].color = color
        persist()
    }

    /// Deletes a Space and archives its tabs. The last Space can't be deleted.
    /// Returns the IDs of tabs that were closed.
    @discardableResult
    func deleteSpace(_ id: UUID) -> [UUID] {
        guard spaces.count > 1, spaces.contains(where: { $0.id == id }) else { return [] }
        let ids = tabs.filter { $0.spaceID == id }.map(\.id)
        closeTabs(ids, reason: .closed)
        spaces.removeAll { $0.id == id }
        if selectedSpaceID == id { selectedSpaceID = spaces[0].id }
        persist()
        return ids
    }

    private static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    // MARK: - Settings

    func updateSettings(_ newValue: BrowserSettings) {
        guard newValue != settings else { return }
        settings = newValue
        persist()
    }

    /// Turns tracker blocking on or off for one site.
    func setTrackerBlocking(_ enabled: Bool, forHost host: String) {
        var newValue = settings
        newValue.trackerBlockingExceptions.removeAll { $0 == host }
        if !enabled { newValue.trackerBlockingExceptions.append(host) }
        updateSettings(newValue)
    }

    // MARK: - Export

    /// Every open tab's address, grouped by Space, as plain text to share.
    func exportText() -> String {
        spaces.map { space in
            let urls = tabs(in: space.id).filter { !$0.isPrivate }.compactMap { $0.url?.absoluteString }
            return ([space.name] + urls).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    // MARK: - Persistence

    /// Everything that's saved to disk. `version` is bumped whenever the
    /// format changes in a way that needs migrating.
    private struct Snapshot: Codable {
        var version: Int = 1
        var spaces: [Space]
        var tabs: [BrowserTab]
        var archive: [ArchivedTab]
        var selectedSpaceID: UUID
        var settings: BrowserSettings
        var lastViewedTabID: UUID?
    }

    nonisolated static var defaultFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("AuraSearch", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it, so a bad
            // update never silently wipes someone's tabs.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            print("AuraSearch: couldn't read saved state (\(error)); backed up to \(backup.lastPathComponent)")
            return nil
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = Snapshot(
            spaces: spaces,
            tabs: tabs.filter { !$0.isPrivate },
            archive: archive,
            selectedSpaceID: selectedSpaceID,
            settings: settings,
            lastViewedTabID: lastViewedTabID
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("AuraSearch: couldn't save state: \(error)")
        }
    }
}
