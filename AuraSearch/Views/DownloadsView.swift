import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Everything you've downloaded, newest first. Tap a file to open it in
/// Quick Look, where Share can save an image to Photos; swipe to delete.
/// The same files are in the Files app, under On My iPhone › Aura Search.
struct DownloadsView: View {
    @Environment(BrowserSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?

    var body: some View {
        let downloads = session.downloads
        NavigationStack {
            List {
                ForEach(downloads.items) { item in
                    if item.status == .finished {
                        Button {
                            previewURL = item.fileURL
                        } label: {
                            DownloadRow(item: item)
                        }
                        .foregroundStyle(.primary)
                    } else {
                        DownloadRow(item: item) { downloads.cancel(item.id) }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { downloads.items[$0].id }
                    for id in ids { downloads.delete(id) }
                }
            }
            .overlay {
                if downloads.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Files you download show up here, and in the Files app under On My iPhone › Aura Search.")
                    )
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Show in Files") { showInFiles() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .quickLookPreview($previewURL)
            .onAppear { downloads.reload() }
        }
    }

    /// Opens the Files app at the Downloads folder.
    private func showInFiles() {
        let path = session.downloads.folder.path(percentEncoded: true)
        if let url = URL(string: "shareddocuments://" + path) {
            openURL(url)
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    /// Shown as a stop button while the file is coming in.
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            DownloadIcon(item: item, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.status == .downloading, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop download")
            }
        }
        .contentShape(Rectangle())
    }
}

/// A small card above the bottom bar for the latest download: its progress
/// while it comes in, then Open. Tap it for the Downloads list, or swipe
/// it down to put it away.
struct DownloadToast: View {
    let item: DownloadItem
    let onOpen: () -> Void
    let onShowList: () -> Void
    let onDismiss: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 12) {
            DownloadIcon(item: item, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.toastDetail)
                    .font(.caption)
                    .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if item.status == .finished {
                Button(action: onOpen) {
                    Text("Open")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 58)
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .contentShape(shape)
        .onTapGesture(perform: onShowList)
        .gesture(
            DragGesture(minimumDistance: 10).onEnded { value in
                if value.translation.height > 16 { onDismiss() }
            }
        )
        .animation(Motion.quick, value: item.status)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows your downloads")
    }
}

/// The file's kind, or a progress ring while it comes in.
private struct DownloadIcon: View {
    let item: DownloadItem
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            switch item.status {
            case .downloading:
                ProgressRing(fraction: item.fraction)
                    .frame(width: size * 0.5, height: size * 0.5)
            case .finished:
                Image(systemName: item.symbolName)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(fraction, 0.04)))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(Motion.progress, value: fraction)
    }
}

extension DownloadItem {
    /// "2.4 MB · 5 min. ago", "45% of 3.2 MB", "Couldn't download".
    var detail: String {
        switch status {
        case .downloading:
            if byteCount > 0 {
                return "\(percent) of \(Self.size(byteCount))"
            }
            return receivedBytes > 0 ? Self.size(receivedBytes) : "Starting…"
        case .finished:
            let when = date.formatted(.relative(presentation: .named))
            return byteCount > 0 ? "\(Self.size(byteCount)) · \(when)" : when
        case .failed:
            return "Couldn't download"
        }
    }

    /// Shorter, for the card above the bottom bar.
    var toastDetail: String {
        switch status {
        case .downloading:
            return byteCount > 0 ? "Downloading… \(percent)" : "Downloading…"
        case .finished:
            return byteCount > 0 ? "Downloaded · \(Self.size(byteCount))" : "Downloaded"
        case .failed:
            return "Couldn't download"
        }
    }

    /// An SF Symbol for the kind of file.
    var symbolName: String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation) {
            return "doc.text"
        }
        return "doc"
    }

    private var percent: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
