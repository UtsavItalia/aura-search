import Foundation

struct BrowserSettings: Codable, Equatable {
    var searchEngine: SearchEngine = .duckDuckGo
    var autoArchive: AutoArchiveInterval = .twelveHours
    var blocksTrackers: Bool = true
    /// Sites where the user turned tracker blocking off because a page broke.
    var trackerBlockingExceptions: [String] = []
    /// Open the search field with the keyboard up when the app launches.
    var autoOpenKeyboard: Bool = true
    /// Open links in their app (YouTube, Maps...) when it's installed.
    var opensLinksInApps: Bool = true
    /// Ask the search engine for suggestions as you type.
    var showsSearchSuggestions: Bool = true
    var appearance: AppAppearance = .system

    init() {}

    /// Whether trackers are blocked on a given site.
    func isBlockingTrackers(on host: String?) -> Bool {
        guard blocksTrackers else { return false }
        guard let host else { return true }
        return !trackerBlockingExceptions.contains(host)
    }

    // Decoded field by field with defaults, so adding a setting in a later
    // version doesn't make older saved state fail to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserSettings()
        searchEngine = (try? c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? defaults.searchEngine
        autoArchive = (try? c.decodeIfPresent(AutoArchiveInterval.self, forKey: .autoArchive)) ?? defaults.autoArchive
        blocksTrackers = (try? c.decodeIfPresent(Bool.self, forKey: .blocksTrackers)) ?? defaults.blocksTrackers
        trackerBlockingExceptions = (try? c.decodeIfPresent([String].self, forKey: .trackerBlockingExceptions)) ?? defaults.trackerBlockingExceptions
        autoOpenKeyboard = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpenKeyboard)) ?? defaults.autoOpenKeyboard
        opensLinksInApps = (try? c.decodeIfPresent(Bool.self, forKey: .opensLinksInApps)) ?? defaults.opensLinksInApps
        showsSearchSuggestions = (try? c.decodeIfPresent(Bool.self, forKey: .showsSearchSuggestions)) ?? defaults.showsSearchSuggestions
        appearance = (try? c.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? defaults.appearance
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How long a tab can sit unused before it moves to the archive,
/// like Arc Search's "dead tab" clean-up. Pinned tabs never auto-archive.
enum AutoArchiveInterval: String, Codable, CaseIterable, Identifiable {
    case never, sixHours, twelveHours, oneDay, oneWeek

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .sixHours: return 6 * 3600
        case .twelveHours: return 12 * 3600
        case .oneDay: return 24 * 3600
        case .oneWeek: return 7 * 24 * 3600
        }
    }

    var label: String {
        switch self {
        case .never: return "Never"
        case .sixHours: return "After 6 hours"
        case .twelveHours: return "After 12 hours"
        case .oneDay: return "After 1 day"
        case .oneWeek: return "After 1 week"
        }
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case duckDuckGo, startpage, brave, google, bing

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        case .google: return "Google"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .startpage: base = "https://www.startpage.com/do/search"
        case .brave: base = "https://search.brave.com/search"
        case .google: base = "https://www.google.com/search"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}
