import SwiftUI

/// The sheet that slides up from the browser's up-arrow button: address,
/// quick actions, page options and tracker blocking for the site.
struct PageMenuView: View {
    let tab: BrowserTab
    let onReader: () -> Void
    let onFind: () -> Void
    let onDownloads: () -> Void

    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingAddress = false
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    @State private var justCopied = false

    private var tint: Color {
        store.space(withID: tab.spaceID)?.color.color ?? .accentColor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                addressPill
                tiles
                pageOptions
                downloadsRow
                tabOptions
                if store.settings.blocksTrackers, let host = tab.url?.host() {
                    trackerCard(host: host)
                }
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(32)
        .sensoryFeedback(.success, trigger: justCopied) { _, copied in copied }
        .tint(tint)
    }

    // MARK: - Address

    private var addressPill: some View {
        HStack(spacing: 2) {
            if isEditingAddress {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                TextField("Search or enter address", text: $addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        session.navigateActiveTab(to: addressText)
                        dismiss()
                    }
                Button("Cancel") {
                    isEditingAddress = false
                }
                .padding(.horizontal, 8)
            } else {
                pillButton("chevron.backward", label: "Back", enabled: session.canGoBack) {
                    session.goBack()
                }
                pillButton("chevron.forward", label: "Forward", enabled: session.canGoForward) {
                    session.goForward()
                }
                Button {
                    startEditingAddress()
                } label: {
                    HStack(spacing: 4) {
                        if tab.url?.scheme == "https" {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(tab.displayHost.isEmpty ? "Enter address" : tab.displayHost)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Edit the address")
                pillButton(justCopied ? "checkmark" : "link", label: "Copy link", enabled: tab.url != nil) {
                    copyLink()
                }
                pillButton(session.isLoading ? "xmark" : "arrow.clockwise",
                           label: session.isLoading ? "Stop" : "Reload",
                           enabled: tab.url != nil) {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 52)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func pillButton(
        _ systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func startEditingAddress() {
        addressText = tab.url?.absoluteString ?? ""
        isEditingAddress = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            addressFocused = true
        }
    }

    private func copyLink() {
        session.copyActiveLink()
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }

    // MARK: - Quick actions

    private var tiles: some View {
        HStack(alignment: .top, spacing: 10) {
            tile("Find on Page", systemImage: "doc.text.magnifyingglass", enabled: tab.url != nil) {
                onFind()
            }
            tile("Reader", systemImage: "doc.plaintext", enabled: tab.url != nil) {
                onReader()
            }
            tile(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin", enabled: true) {
                store.togglePin(tab.id)
            }
            if let url = tab.url {
                ShareLink(item: url) {
                    tileLabel("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            } else {
                tileLabel("Share", systemImage: "square.and.arrow.up")
                    .opacity(0.35)
            }
        }
    }

    private func tile(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            tileLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func tileLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 66)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Page options

    private var pageOptions: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Page Zoom", systemImage: "textformat.size")
                Spacer()
                HStack(spacing: 0) {
                    Button {
                        session.adjustZoom(by: -0.1)
                    } label: {
                        Image(systemName: "minus").frame(width: 44, height: 34)
                    }
                    .disabled(session.pageZoom <= BrowserSession.zoomRange.lowerBound)
                    .accessibilityLabel("Zoom out")

                    Button {
                        session.resetZoom()
                    } label: {
                        Text("\(Int((session.pageZoom * 100).rounded()))%")
                            .font(.subheadline.monospacedDigit())
                            .frame(minWidth: 52, minHeight: 34)
                    }
                    .accessibilityLabel("Reset zoom")

                    Button {
                        session.adjustZoom(by: 0.1)
                    } label: {
                        Image(systemName: "plus").frame(width: 44, height: 34)
                    }
                    .disabled(session.pageZoom >= BrowserSession.zoomRange.upperBound)
                    .accessibilityLabel("Zoom in")
                }
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().padding(.leading, 52)

            Toggle(isOn: Binding(
                get: { session.desktopSiteTabs.contains(tab.id) },
                set: { _ in session.toggleDesktopSite() }
            )) {
                Label("Request Desktop Site", systemImage: "desktopcomputer")
            }
            .disabled(tab.url == nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Downloads

    private var downloadsRow: some View {
        let active = session.downloads.activeCount
        return Button(action: onDownloads) {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                Spacer()
                if active > 0 {
                    Text(active == 1 ? "1 in progress" : "\(active) in progress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Tab options

    private var tabOptions: some View {
        let otherSpaces = store.spaces.filter { $0.id != tab.spaceID }
        return VStack(spacing: 0) {
            if !otherSpaces.isEmpty {
                Menu {
                    ForEach(otherSpaces) { space in
                        Button(space.name) { store.moveTab(tab.id, to: space.id) }
                    }
                } label: {
                    optionRow("Move to Space", systemImage: "arrow.right.square")
                }
                Divider().padding(.leading, 52)
            }
            Button(role: .destructive) {
                dismiss()
                session.closeTab(tab.id)
            } label: {
                optionRow("Close Tab", systemImage: "xmark")
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func optionRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Trackers

    /// WebKit doesn't report how many requests its content blocker stopped,
    /// so this shows whether blocking is on for the site rather than a count.
    private func trackerCard(host: String) -> some View {
        let blocking = store.settings.isBlockingTrackers(on: host)
        let site = tab.displayHost
        let title: String = blocking ? "Blocking trackers on \(site)" : "Tracker blocking is off for \(site)"
        let detail: String = blocking
            ? "Page not working? Tap to turn blocking off for this site."
            : "Tap to turn it back on."
        return Button {
            session.setTrackerBlockingForActiveSite(!blocking)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: blocking ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.title3)
                    .foregroundStyle(blocking ? tint : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
