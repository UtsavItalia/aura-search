import SwiftUI

struct SettingsView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var showingArchive = false
    @State private var showingHistory = false
    @State private var showingDownloads = false
    @State private var confirmingClearData = false
    @State private var clearedData = 0

    private var settings: Binding<BrowserSettings> {
        Binding(get: { store.settings }, set: { store.updateSettings($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingArchive = true
                    } label: {
                        LabeledContent {
                            Text("\(store.archive.count)")
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showingHistory = true
                    } label: {
                        LabeledContent {
                            Text("\(session.history.entries.filter { $0.visitCount > 0 }.count)")
                        } label: {
                            Label("History", systemImage: "clock")
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showingDownloads = true
                    } label: {
                        LabeledContent {
                            Text("\(session.downloads.items.count)")
                        } label: {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Picker(selection: settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.name).tag(engine)
                        }
                    } label: {
                        Label("Search Engine", systemImage: "magnifyingglass")
                    }
                    Toggle(isOn: settings.showsSearchSuggestions) {
                        Label("Search Suggestions", systemImage: "text.magnifyingglass")
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text("Suggestions send what you type to \(store.settings.searchEngine.name) as you type. They're always off for private tabs.")
                }

                Section {
                    Picker(selection: settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Toggle(isOn: settings.autoOpenKeyboard) {
                        Label("Auto-Open Keyboard", systemImage: "keyboard")
                    }
                    Picker(selection: settings.autoArchive) {
                        ForEach(AutoArchiveInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    } label: {
                        Label("Archive Inactive Tabs", systemImage: "archivebox")
                    }
                    Picker(selection: settings.opensLinksInApps) {
                        Text("Native App").tag(true)
                        Text("Aura Search").tag(false)
                    } label: {
                        Label("Open App Links In", systemImage: "arrow.up.forward.app")
                    }
                } header: {
                    Text("Browsing")
                } footer: {
                    Text("Inactive tabs are unpinned tabs you haven't opened in that long. They move to the Archive, where you can restore them.")
                }

                Section {
                    Toggle(isOn: settings.blocksTrackers) {
                        Label("Block Trackers", systemImage: "shield.lefthalf.filled")
                    }
                    if !store.settings.trackerBlockingExceptions.isEmpty {
                        NavigationLink {
                            TrackerExceptionsView()
                        } label: {
                            LabeledContent {
                                Text("\(store.settings.trackerBlockingExceptions.count)")
                            } label: {
                                Label("Sites With Blocking Off", systemImage: "shield.slash")
                            }
                        }
                    }
                    Button(role: .destructive) {
                        confirmingClearData = true
                    } label: {
                        Label("Clear Browsing Data…", systemImage: "eraser")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Blocking stops common ad and analytics trackers from loading. Changes apply from each tab's next page load.")
                }

                Section {
                    ShareLink(item: store.exportText()) {
                        Label("Export Open Tabs", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Shares the address of every open tab, grouped by Space.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Text("Aura Search is free and open source.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: store.settings.blocksTrackers) { _, _ in
                session.applyContentBlocking()
            }
            .onChange(of: store.settings.autoArchive) { _, _ in
                session.archiveStaleTabs()
            }
            .sheet(isPresented: $showingArchive) {
                ArchiveView()
                    .environment(store)
                    .environment(session)
            }
            .sheet(isPresented: $showingDownloads) {
                DownloadsView()
                    .environment(store)
                    .environment(session)
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView { url in
                    showingHistory = false
                    dismiss()
                    session.openNewTab(from: url.absoluteString)
                }
                .environment(store)
                .environment(session)
            }
            .confirmationDialog(
                "Clear browsing data?",
                isPresented: $confirmingClearData,
                titleVisibility: .visible
            ) {
                Button("Clear History and Site Data", role: .destructive) {
                    Task {
                        await session.clearBrowsingData()
                        clearedData += 1
                    }
                }
            } message: {
                Text("Removes your history, cookies and site data. You'll be signed out of websites. Your tabs, Spaces and Archive stay.")
            }
            .sensoryFeedback(.success, trigger: clearedData)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }
}

/// Sites where tracker blocking was turned off from the page menu.
private struct TrackerExceptionsView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session

    var body: some View {
        let hosts = store.settings.trackerBlockingExceptions
        List {
            Section {
                ForEach(hosts, id: \.self) { host in
                    Text(host)
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.setTrackerBlocking(true, forHost: hosts[index])
                    }
                    session.applyContentBlocking()
                }
            } footer: {
                Text("Swipe a site to turn blocking back on for it.")
            }
        }
        .overlay {
            if hosts.isEmpty {
                ContentUnavailableView("No exceptions", systemImage: "shield.lefthalf.filled")
            }
        }
        .navigationTitle("Blocking Off")
        .navigationBarTitleDisplayMode(.inline)
    }
}
