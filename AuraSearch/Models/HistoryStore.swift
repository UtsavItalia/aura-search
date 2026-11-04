import Foundation
import Observation

/// A page you've visited. One entry per address; repeat visits add up.
struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    /// `HistoryStore.key(for: url)`, stored so lookups don't re-parse URLs.
    let key: String
    var title: String
    var visitCount: Int
    /// How often you typed this address yourself. Counts double in ranking,
    /// since a typed address is one you clearly want back.
    var typedCount: Int
    var lastVisitedAt: Date

    var displayTitle: String {
        title.isEmpty ? (HistoryStore.bareHost(of: url) ?? url.absoluteString) : title
    }

    /// The address as you'd type it: no scheme, no "www.", no query.
    var displayURL: String {
        let host = HistoryStore.bareHost(of: url) ?? ""
        let path = url.path()
        return path.isEmpty || path == "/" ? host : host + path
    }
}

/// Browsing history, for address autocomplete, visited-site suggestions and
/// the History screen. Private tabs and search result pages are never
/// recorded. Kept on this device only.
@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    /// Oldest entries beyond this are dropped.
    static let limit = 5000

    private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// - Parameter fileURL: where history is saved; `nil` keeps it in memory
    ///   (used by tests).
    init(fileURL: URL? = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = saved.entries
        }
    }

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AuraSearch", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    // MARK: - Recording

    func recordVisit(url: URL, title: String?, at date: Date = .now) {
        guard Self.isRecordable(url) else { return }
        let key = Self.key(for: url)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].visitCount += 1
            entries[index].lastVisitedAt = date
            if let title, !title.isEmpty { entries[index].title = title }
        } else {
            entries.append(HistoryEntry(
                id: UUID(),
                url: url,
                key: key,
                title: title ?? "",
                visitCount: 1,
                typedCount: 0,
                lastVisitedAt: date
            ))
            trimToLimit()
        }
        scheduleSave()
    }

    /// Pages often set their title after loading; keep the latest one.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        let key = Self.key(for: url)
        guard let index = entries.firstIndex(where: { $0.key == key }),
              entries[index].title != title else { return }
        entries[index].title = title
        scheduleSave()
    }

    /// An address you typed and opened. The visit itself is recorded when
    /// the page loads.
    func recordTyped(_ url: URL, at date: Date = .now) {
        guard Self.isRecordable(url) else { return }
        let key = Self.key(for: url)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].typedCount += 1
        } else {
            entries.append(HistoryEntry(
                id: UUID(), url: url, key: key, title: "", visitCount: 0, typedCount: 1, lastVisitedAt: date
            ))
            trimToLimit()
        }
        scheduleSave()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        saveNow()
    }

    // MARK: - Autocomplete

    /// The address to complete what you're typing to, or `nil`. Completes to
    /// a site ("goo" → "google.com") until you type a "/", then to a full
    /// address on that site. Picks the most-used, most-recent match.
    func completion(for typed: String, now: Date = .now) -> String? {
        let text = typed.lowercased()
        guard !text.isEmpty, !text.contains(" "), !text.contains("://") else { return nil }
        // Keep a "www." you typed, but match sites with or without it.
        let prefix = text.hasPrefix("www.") ? "www." : ""
        let needle = String(text.dropFirst(prefix.count))
        guard !needle.isEmpty else { return nil }

        if !needle.contains("/") {
            var scores: [String: Double] = [:]
            for entry in entries {
                guard let host = Self.bareHost(of: entry.url), host.hasPrefix(needle), host != needle else { continue }
                scores[host, default: 0] += Self.score(entry, now: now)
            }
            return scores.max { $0.value < $1.value }.map { prefix + $0.key }
        }

        let best = entries
            .filter { $0.displayURL.lowercased().hasPrefix(needle) && $0.displayURL.lowercased() != needle }
            .max { Self.score($0, now: now) < Self.score($1, now: now) }
        return best.map { prefix + $0.displayURL.lowercased() }
    }

    /// Visited pages whose title or address contains the text, best first.
    func matches(for query: String, limit: Int, excluding excludedURLs: Set<String> = [], now: Date = .now) -> [HistoryEntry] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return Array(
            entries
                .filter { entry in
                    entry.visitCount > 0 &&
                    !excludedURLs.contains(entry.key) &&
                    (entry.title.lowercased().contains(needle) || entry.displayURL.lowercased().contains(needle))
                }
                .sorted { Self.score($0, now: now) > Self.score($1, now: now) }
                .prefix(limit)
        )
    }

    // MARK: - Rules

    /// Frecency: how often, weighted by how recently. Typed visits count
    /// double, and a visit's weight halves every two weeks.
    static func score(_ entry: HistoryEntry, now: Date) -> Double {
        let ageInDays = max(now.timeIntervalSince(entry.lastVisitedAt), 0) / 86_400
        return Double(entry.visitCount + 2 * entry.typedCount) * pow(0.5, ageInDays / 14)
    }

    /// Web pages only, and not search results: a search is quicker to run
    /// again than to find in history, and would crowd out real sites.
    static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { return false }
        return !SearchEngine.allCases.contains { $0.isResultsPage(url) }
    }

    /// One entry per address, ignoring "#section" links within a page.
    nonisolated static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        let host = components.host?.lowercased()
        components.host = host
        return components.string ?? url.absoluteString
    }

    nonisolated static func bareHost(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func trimToLimit() {
        guard entries.count > Self.limit else { return }
        entries.sort { $0.lastVisitedAt > $1.lastVisitedAt }
        entries.removeLast(entries.count - Self.limit)
    }

    // MARK: - Saving

    private struct Saved: Codable {
        var version = 1
        var entries: [HistoryEntry]
    }

    /// Visits come in bursts, so saves wait a moment and batch up.
    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes history now. Also called when the app goes to the background.
    func saveNow() {
        saveTask?.cancel()
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Saved(entries: entries))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("AuraSearch: couldn't save history: \(error)")
        }
    }
}
