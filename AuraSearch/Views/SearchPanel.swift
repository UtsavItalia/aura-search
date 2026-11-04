import SwiftUI

/// The search panel: slides up at launch over your last page, and from "+".
/// Type to search or enter an address, pick a suggestion, jump to a
/// matching open tab, or switch on private browsing for the next tab.
///
/// A custom panel rather than a sheet, so it runs edge to edge like Arc's
/// and the keyboard slides up underneath it.
struct SearchPanel: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var suggestions: [String] = []
    /// The address from history that what you're typing completes to, like
    /// "google.com" for "goo". Shown highlighted after the cursor; Go opens it.
    @State private var completion: String?
    @State private var previousQuery = ""
    @FocusState private var fieldFocused: Bool
    /// How far the panel has been pulled down. Kept when you let go past
    /// the threshold, so it carries on down from there instead of jumping back.
    @State private var dragOffset: CGFloat = 0

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The typed text resolves to a site rather than a search.
    private var typedAddress: URL? {
        let engine = store.settings.searchEngine
        guard let url = URLResolver.resolve(trimmedQuery, engine: engine),
              url != engine.searchURL(for: trimmedQuery) else { return nil }
        return url
    }

    var body: some View {
        let isPrivate = session.prefersPrivateTabs
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .gesture(pullToClose)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if trimmedQuery.isEmpty {
                        idleRows
                    } else {
                        typingRows
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if trimmedQuery.isEmpty, isPrivate {
                    privateNotice
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { panelBackground(isPrivate: isPrivate) }
        .offset(y: dragOffset)
        // Private browsing turns the whole panel, keyboard included, dark.
        .environment(\.colorScheme, isPrivate ? .dark : colorScheme)
        .animation(.easeInOut(duration: 0.25), value: isPrivate)
        .sensoryFeedback(.selection, trigger: isPrivate)
        // Focus straight away, so the keyboard rises with the panel.
        .onAppear { fieldFocused = true }
        .task {
            // In case the first focus didn't take while the panel was appearing.
            try? await Task.sleep(for: .milliseconds(250))
            if !fieldFocused, !session.isSearchClosing { fieldFocused = true }
        }
        .onChange(of: session.isSearchClosing) { _, closing in
            if closing {
                fieldFocused = false
            } else if session.isSearchPresented {
                // Brought back up on its way out: it never left the screen,
                // so it has to take the keyboard back itself.
                withAnimation(BrowserSession.searchAnimation) { dragOffset = 0 }
                fieldFocused = true
            }
        }
        .task(id: suggestionKey) {
            await loadSuggestions()
        }
        .onChange(of: query) { _, newValue in
            updateCompletion(for: newValue)
        }
    }

    // MARK: - Panel

    /// Frosted and slightly see-through normally; solid dark when private,
    /// so it's obvious which kind of tab you're about to open.
    private func panelBackground(isPrivate: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous)
        return shape
            .fill(isPrivate ? AnyShapeStyle(Color(white: 0.14)) : AnyShapeStyle(.regularMaterial))
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 20, y: -4)
            // Runs under the keyboard and the home indicator.
            .ignoresSafeArea()
    }

    /// Pulling the panel down past 70pt, or flicking it, closes it.
    private var pullToClose: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !session.isSearchClosing else { return }
                dragOffset = max(value.translation.height, 0)
            }
            .onEnded { value in
                guard !session.isSearchClosing else { return }
                if value.translation.height > 70 || value.predictedEndTranslation.height > 200 {
                    close()
                } else {
                    withAnimation(BrowserSession.searchAnimation) { dragOffset = 0 }
                }
            }
    }

    private func close() {
        fieldFocused = false
        session.dismissSearch()
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 10) {
            TextField("Search…", text: $query)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit { open(completion ?? trimmedQuery) }
                .overlay(alignment: .leading) { completionGhost }

            privateToggle

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: 48)
        .background(Color.primary.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// The rest of the completed address, drawn right after what you typed
    /// and highlighted like a selection, as in Arc and Safari.
    @ViewBuilder
    private var completionGhost: some View {
        if let suffix = completionSuffix {
            HStack(spacing: 0) {
                Text(query).hidden()
                Text(suffix)
                    .background(Color.accentColor.opacity(0.28))
            }
            .font(.body)
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var completionSuffix: String? {
        // Long text scrolls inside the field, where the overlay can't follow.
        guard let completion, query.count < 28, completion.count > query.count,
              completion.lowercased().hasPrefix(query.lowercased()) else { return nil }
        return String(completion.dropFirst(query.count))
    }

    /// Completes only while you type forwards. Deleting drops the
    /// completion, so backspace never fights you.
    private func updateCompletion(for newValue: String) {
        defer { previousQuery = newValue }
        let typingForward = newValue.count > previousQuery.count && newValue.hasPrefix(previousQuery)
        guard typingForward, !newValue.hasSuffix(" ") else {
            completion = nil
            return
        }
        completion = session.history.completion(for: newValue)
    }

    /// Just an icon when off; "Private" spelled out when on.
    private var privateToggle: some View {
        let isPrivate = session.prefersPrivateTabs
        return Button {
            withAnimation(.snappy) { session.prefersPrivateTabs.toggle() }
        } label: {
            HStack(spacing: 5) {
                if isPrivate {
                    Text("Private")
                        .font(.subheadline)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Image(systemName: isPrivate ? "eye.slash.fill" : "eye.slash")
                    .font(.body)
            }
            .foregroundStyle(isPrivate ? .primary : .tertiary)
            .frame(minWidth: 32, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Private browsing")
        .accessibilityValue(isPrivate ? "On" : "Off")
    }

    // MARK: - Rows before typing

    @ViewBuilder
    private var idleRows: some View {
        if !session.prefersPrivateTabs, !recentTabs.isEmpty {
            sectionLabel("Recent")
            ForEach(recentTabs) { tab in
                tabRow(tab)
            }
        }
    }

    private var privateNotice: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("You're browsing privately")
                .font(.headline)
            Text("Nothing from private tabs is saved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .allowsHitTesting(false)
    }

    /// The tabs you used most recently, other than the one on screen.
    private var recentTabs: [BrowserTab] {
        Array(
            store.tabs
                .filter { $0.id != store.activeTabID && $0.url != nil }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
                .prefix(4)
        )
    }

    // MARK: - Rows while typing

    @ViewBuilder
    private var typingRows: some View {
        if let completion {
            row(systemImage: "globe") {
                open(completion)
            } label: {
                highlighted(completion)
            }
        }

        if let address = typedAddress {
            row(systemImage: "globe") {
                open(trimmedQuery)
            } label: {
                Text(address.host() ?? trimmedQuery)
            }
        } else {
            row(systemImage: "magnifyingglass") {
                open(trimmedQuery)
            } label: {
                Text(trimmedQuery)
            }
        }

        ForEach(visitedSites) { entry in
            historyRow(entry)
        }

        ForEach(suggestions, id: \.self) { suggestion in
            row(systemImage: "magnifyingglass") {
                open(suggestion)
            } label: {
                highlighted(suggestion)
            } trailing: {
                // Puts the suggestion in the field to keep typing from it.
                Button {
                    query = suggestion + " "
                } label: {
                    Image(systemName: "arrow.up.left")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(suggestion)")
            }
        }

        if !matchingTabs.isEmpty {
            sectionLabel("Open tabs")
            ForEach(matchingTabs) { tab in
                tabRow(tab)
            }
        }
    }

    /// The part you typed in the normal weight, the rest of the suggestion
    /// bold, so the completion is what stands out.
    private func highlighted(_ suggestion: String) -> Text {
        let typed = trimmedQuery
        guard suggestion.lowercased().hasPrefix(typed.lowercased()) else {
            return Text(suggestion)
        }
        let rest = String(suggestion.dropFirst(typed.count))
        return Text(String(suggestion.prefix(typed.count))).foregroundStyle(.secondary)
            + Text(rest).fontWeight(.semibold)
    }

    /// Pages you've visited that match, best first. Leaves out the site
    /// already completed above and pages open in a tab (listed below).
    private var visitedSites: [HistoryEntry] {
        let openTabs = Set(store.tabs.compactMap { $0.url.map(HistoryStore.key(for:)) })
        return session.history
            .matches(for: trimmedQuery, limit: 4, excluding: openTabs)
            .filter { $0.displayURL.lowercased() != completion }
            .prefix(3)
            .map { $0 }
    }

    /// Open tabs whose title or address contains the text.
    private var matchingTabs: [BrowserTab] {
        let needle = trimmedQuery.lowercased()
        return Array(
            store.tabs
                .filter { tab in
                    tab.id != store.activeTabID &&
                    (tab.title.lowercased().contains(needle) ||
                     (tab.url?.absoluteString.lowercased().contains(needle) ?? false))
                }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
                .prefix(4)
        )
    }

    // MARK: - Row building blocks

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private func row<RowLabel: View, Trailing: View>(
        systemImage: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> RowLabel,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    label()
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 24)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            trailing()
                .padding(.trailing, 12)
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        Button {
            open(entry.url.absoluteString)
        } label: {
            HStack(spacing: 14) {
                FaviconView(url: entry.url, title: entry.displayTitle, tint: .gray)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .lineLimit(1)
                    Text(entry.displayURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("From history")
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        Button {
            session.activate(tab.id)
            close()
        } label: {
            HStack(spacing: 14) {
                FaviconView(tab: tab, tint: store.space(withID: tab.spaceID)?.color.color ?? .gray)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle)
                        .lineLimit(1)
                    Text(tab.isPrivate ? "Private" : tab.displayHost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Switch to tab")
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    // MARK: - Suggestions

    /// Changes whenever suggestions need refetching; `.task(id:)` cancels
    /// the previous request, which also debounces fast typing.
    private var suggestionKey: String {
        "\(session.prefersPrivateTabs)|\(store.settings.searchEngine.rawValue)|\(trimmedQuery)"
    }

    private func loadSuggestions() async {
        let text = trimmedQuery
        guard store.settings.showsSearchSuggestions,
              !session.prefersPrivateTabs,
              !text.isEmpty,
              typedAddress == nil else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let results = await SearchSuggestions.fetch(for: text, engine: store.settings.searchEngine)
        guard !Task.isCancelled else { return }
        suggestions = results
    }

    // MARK: - Actions

    private func open(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.openNewTab(from: text, isPrivate: session.prefersPrivateTabs)
        close()
    }
}

/// Flat rows: no background until pressed.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
    }
}
