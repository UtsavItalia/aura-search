import SwiftUI

@main
@MainActor
struct AuraSearchApp: App {
    @State private var store: TabStore
    @State private var session: BrowserSession

    init() {
        let store = TabStore()
        _store = State(initialValue: store)
        _session = State(initialValue: BrowserSession(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(session)
                .task { await session.prepare() }
        }
    }
}
