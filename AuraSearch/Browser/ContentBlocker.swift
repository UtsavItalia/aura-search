import WebKit

/// Compiles the bundled tracker list into a WebKit content blocker.
/// WebKit applies it natively, so blocking costs no JavaScript and no
/// per-request work in our code.
@MainActor
final class ContentBlocker {
    private(set) var ruleList: WKContentRuleList?

    private static let identifier = "aura-trackers"

    func load() async {
        guard ruleList == nil,
              let url = Bundle.main.url(forResource: "tracker-blocklist", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else { return }

        ruleList = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: Self.identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    print("AuraSearch: tracker list failed to compile: \(error)")
                }
                continuation.resume(returning: list)
            }
        }
    }
}
