import Foundation

/// A single browser tab.
///
/// Identity is the `id`, assigned once and never changed. The URL is just
/// what the tab is currently showing: it changes on every link you follow,
/// so it can't be what makes a tab "the same tab".
struct BrowserTab: Identifiable, Codable, Hashable {
    let id: UUID
    var spaceID: UUID
    var url: URL?
    var title: String
    var isPinned: Bool
    let createdAt: Date
    var lastActiveAt: Date
    /// `nil` means a local-only tab. Filled in once tab sync ships (phase 2),
    /// so a synced tab is the same type with extra information attached.
    var sync: SyncMetadata?
    /// Private tabs keep their cookies in memory only and are never saved,
    /// archived or synced. Not encoded, since private tabs never reach disk.
    var isPrivate: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, spaceID, url, title, isPinned, createdAt, lastActiveAt, sync
    }

    init(
        id: UUID = UUID(),
        spaceID: UUID,
        url: URL?,
        title: String = "",
        isPinned: Bool = false,
        createdAt: Date = .now,
        lastActiveAt: Date = .now,
        sync: SyncMetadata? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.sync = sync
        self.isPrivate = isPrivate
    }

    /// What to show in lists: the page title, else the host, else a placeholder.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host(), !host.isEmpty { return host }
        return "New Tab"
    }

    /// Host without a leading "www.", for compact display.
    var displayHost: String {
        guard let host = url?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Where a synced tab came from. Unused until phase 2.
struct SyncMetadata: Codable, Hashable {
    /// The device that published this tab, as reported by Firefox Sync.
    var sourceDeviceID: String
    var lastSyncedAt: Date
}

/// A tab that was closed by hand or auto-archived, kept so it can be restored.
struct ArchivedTab: Identifiable, Codable, Hashable {
    enum Reason: String, Codable {
        case closed
        case autoArchived
    }

    var tab: BrowserTab
    var archivedAt: Date
    var reason: Reason

    var id: UUID { tab.id }
}
