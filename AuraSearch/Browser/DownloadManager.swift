import Foundation
import Observation
import WebKit

/// A file downloaded from a page: still coming in, saved, or failed.
struct DownloadItem: Identifiable, Equatable {
    enum Status: Equatable {
        case downloading
        case finished
        case failed
    }

    let id: UUID
    var filename: String
    /// Where the file is saved. `nil` until WebKit has named it, or if it failed.
    var fileURL: URL?
    var status: Status
    /// 0 to 1 while downloading.
    var fraction: Double = 0
    /// The file's size in bytes, or 0 while it isn't known.
    var byteCount: Int64 = 0
    var receivedBytes: Int64 = 0
    var date: Date
}

/// Files downloaded from pages. They're saved in the app's Downloads
/// folder, which the Files app shows under On My iPhone › Aura Search,
/// so the folder itself is the list: nothing else is stored.
@MainActor
@Observable
final class DownloadManager {
    /// Downloads in progress, then saved files, newest first.
    private(set) var items: [DownloadItem] = []
    /// The download shown in the card above the bottom bar, if any.
    private(set) var toastID: UUID?
    /// Whether the Downloads list is up.
    var isListPresented = false
    /// A saved file open in Quick Look, from the card's Open button.
    var previewURL: URL?

    /// Documents/Downloads.
    let folder: URL

    private let delegate: DownloadDelegate
    /// Downloads in progress, by item.
    @ObservationIgnored private var downloads: [UUID: WKDownload] = [:]
    /// Where each download in progress is being written.
    @ObservationIgnored private var destinations: [UUID: URL] = [:]
    @ObservationIgnored private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    /// Keeps a file's row the same each time the folder is read again.
    @ObservationIgnored private var idsByName: [String: UUID] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(folder: URL = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)) {
        self.folder = folder
        self.delegate = DownloadDelegate()
        delegate.manager = self
        // Made up front so the app's folder is there in Files from the start.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    var toastItem: DownloadItem? {
        guard let toastID else { return nil }
        return items.first { $0.id == toastID }
    }

    var activeCount: Int {
        items.filter { $0.status == .downloading }.count
    }

    // MARK: - Starting

    /// Takes over a download WebKit has started from a page.
    func track(_ download: WKDownload) {
        let id = UUID()
        download.delegate = delegate
        downloads[id] = download
        // A placeholder until WebKit suggests the real name.
        let guess = download.originalRequest?.url?.lastPathComponent ?? ""
        let item = DownloadItem(
            id: id,
            filename: guess.isEmpty || guess == "/" ? "Download" : guess,
            fileURL: nil,
            status: .downloading,
            date: .now
        )
        items.insert(item, at: 0)
        // Hops to the main actor itself, whichever thread WebKit reports from.
        progressObservations[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let total = progress.totalUnitCount
            let received = progress.completedUnitCount
            Task { @MainActor [weak self] in
                self?.updateProgress(id, fraction: fraction, totalBytes: total, receivedBytes: received)
            }
        }
        // Long downloads don't keep the card up; it comes back when they finish.
        showToast(id, for: .seconds(6))
    }

    /// Where WebKit should write the file: the suggested name, numbered if
    /// it's taken. `nil` cancels the download.
    fileprivate func destination(for download: WKDownload, suggestedFilename: String, expectedLength: Int64) -> URL? {
        guard let id = itemID(for: download) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let taken = Set(onDisk).union(destinations.values.map(\.lastPathComponent))
        let name = DownloadRules.availableName(for: suggestedFilename, taken: taken)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        destinations[id] = url
        idsByName[name] = id
        update(id) { item in
            item.filename = name
            item.fileURL = url
            if expectedLength > 0 { item.byteCount = expectedLength }
        }
        return url
    }

    // MARK: - Progress and the end

    private func updateProgress(_ id: UUID, fraction: Double, totalBytes: Int64, receivedBytes: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .downloading else { return }
        // Progress fires for every chunk; only redraw for a visible change.
        guard abs(items[index].fraction - fraction) >= 0.01 || fraction >= 1 else { return }
        items[index].fraction = fraction
        items[index].receivedBytes = receivedBytes
        if totalBytes > 0 { items[index].byteCount = totalBytes }
    }

    fileprivate func finished(_ download: WKDownload) {
        guard let id = end(download) else { return }
        update(id) { item in
            item.status = .finished
            item.fraction = 1
            item.date = .now
            if let url = item.fileURL, let size = Self.fileSize(at: url) {
                item.byteCount = size
            }
        }
        showToast(id, for: .seconds(4))
    }

    fileprivate func failed(_ download: WKDownload, error: Error) {
        let file = itemID(for: download).flatMap { destinations[$0] }
        guard let id = end(download) else { return }
        // Don't leave half a file behind.
        if let file { try? FileManager.default.removeItem(at: file) }
        update(id) { item in
            item.status = .failed
            item.fileURL = nil
        }
        showToast(id, for: .seconds(4))
    }

    /// Stops following a download. Returns its item, if it was ours.
    private func end(_ download: WKDownload) -> UUID? {
        guard let id = itemID(for: download) else { return nil }
        downloads[id] = nil
        destinations[id] = nil
        progressObservations[id]?.invalidate()
        progressObservations[id] = nil
        return id
    }

    private func itemID(for download: WKDownload) -> UUID? {
        downloads.first { $0.value === download }?.key
    }

    // MARK: - Managing

    /// Stops a download in progress and removes it without a trace.
    func cancel(_ id: UUID) {
        guard let download = downloads[id] else { return }
        let file = destinations[id]
        _ = end(download)
        remove(id)
        download.cancel { _ in
            // Once WebKit has stopped writing to it.
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Deletes a saved file, or stops a download in progress.
    func delete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.status == .downloading {
            cancel(id)
            return
        }
        if let url = item.fileURL {
            try? FileManager.default.removeItem(at: url)
            idsByName[url.lastPathComponent] = nil
        }
        remove(id)
    }

    /// Reads the folder again, for files added or removed in the Files app.
    func reload() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        // Files still being written are already listed, as downloads.
        let inProgress = Set(destinations.values.map(\.lastPathComponent))
        var files: [DownloadItem] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard !inProgress.contains(name) else { continue }
            let id = idsByName[name] ?? UUID()
            idsByName[name] = id
            files.append(DownloadItem(
                id: id,
                filename: name,
                fileURL: url,
                status: .finished,
                fraction: 1,
                byteCount: Int64(values.fileSize ?? 0),
                date: values.contentModificationDate ?? .distantPast
            ))
        }
        let live = items.filter { $0.status != .finished }
        items = live + files.sorted { $0.date > $1.date }
    }

    // MARK: - The card above the bottom bar

    /// Shows a download in the card, for a while or until replaced.
    private func showToast(_ id: UUID, for duration: Duration?) {
        toastTask?.cancel()
        toastTask = nil
        toastID = id
        guard let duration else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toastID = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toastID = nil
    }

    /// Opens a saved file in Quick Look, from the card.
    func preview(_ item: DownloadItem) {
        dismissToast()
        previewURL = item.fileURL
    }

    // MARK: - Helpers

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if toastID == id { dismissToast() }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }
}

/// Passes WebKit's download callbacks to the manager.
@MainActor
private final class DownloadDelegate: NSObject, WKDownloadDelegate {
    weak var manager: DownloadManager?

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        manager?.destination(
            for: download,
            suggestedFilename: suggestedFilename,
            expectedLength: response.expectedContentLength
        )
    }

    func downloadDidFinish(_ download: WKDownload) {
        manager?.finished(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        manager?.failed(download, error: error)
    }
}

/// Decisions about downloads that don't need WebKit, kept apart so they
/// can be tested.
enum DownloadRules {
    /// Whether a Content-Disposition header asks for the file to be saved
    /// rather than shown, as Unsplash's Download button does.
    static func isAttachment(_ contentDisposition: String?) -> Bool {
        guard let value = contentDisposition?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() else { return false }
        return value == "attachment" || value.hasPrefix("attachment;") || value.hasPrefix("attachment ")
    }

    /// A safe name that isn't taken yet: "photo.jpg", then "photo 2.jpg",
    /// "photo 3.jpg"... Compared ignoring case, as Files does.
    static func availableName(for suggested: String, taken: Set<String>) -> String {
        let name = sanitized(suggested)
        let taken = Set(taken.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    /// No slashes or colons, not hidden, and short enough for the disk.
    static func sanitized(_ suggested: String) -> String {
        var name = suggested
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Download" }
        // A name starting with a dot would be hidden in Files.
        if name.hasPrefix(".") { name = "Download" + name }
        // Names are limited to 255 bytes; this keeps room for a number.
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let dotExt = ext.isEmpty ? "" : "." + ext
            var base = (name as NSString).deletingPathExtension
            while base.utf8.count + dotExt.utf8.count > 200, !base.isEmpty {
                base.removeLast()
            }
            name = base + dotExt
        }
        return name
    }
}
