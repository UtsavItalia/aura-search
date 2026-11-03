import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import UIKit
import WebKit

/// Page previews for the tab cards.
///
/// A snapshot is taken when you leave a tab and after each page load, then
/// kept in memory and cached on disk so cards still have previews after a
/// relaunch. Images are downscaled, since a full-resolution screenshot is
/// ~12 MB in memory and a card only needs a fraction of that.
@MainActor
@Observable
final class SnapshotStore {
    /// Full previews, for showing while a tab reloads.
    private(set) var images: [UUID: UIImage] = [:]
    /// Tiny, heavily blurred versions for the tab cards: just the page's
    /// colors, with no text left to smear. A few KB each, so they're kept
    /// even when the full previews are dropped from memory.
    private(set) var cardPreviews: [UUID: UIImage] = [:]

    /// Most snapshots kept in memory; older ones reload from disk on demand.
    static let memoryLimit = 24
    /// Render scale of stored previews. Screens are 3x; cards are smaller
    /// than the screen, so 1.5x still looks sharp.
    static let renderScale: CGFloat = 1.5

    private let directory: URL?
    @ObservationIgnored private var loadOrder: [UUID] = []

    init(directory: URL? = SnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AuraSearch", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    /// Snapshots a web view that's on screen. Private tabs pass
    /// `savesToDisk: false`, so their pages never leave memory.
    func capture(_ webView: WKWebView, for id: UUID, savesToDisk: Bool = true) async {
        guard webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0 else { return }

        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image else { return }

        let preview = Self.downscaled(image)
        insert(preview, for: id)
        if savesToDisk { save(preview, for: id) }
    }

    /// Loads a cached snapshot from disk if it isn't in memory yet.
    func loadIfNeeded(_ id: UUID) async {
        guard images[id] == nil, let image = await loadFromDisk(id) else { return }
        guard images[id] == nil else { return }
        insert(image, for: id)
    }

    /// Loads just the card preview, without keeping the full image in memory.
    func loadCardPreviewIfNeeded(_ id: UUID) async {
        guard cardPreviews[id] == nil else { return }
        if let image = images[id] {
            cardPreviews[id] = Self.cardPreview(from: image)
            return
        }
        guard let image = await loadFromDisk(id), cardPreviews[id] == nil else { return }
        cardPreviews[id] = Self.cardPreview(from: image)
    }

    private func loadFromDisk(_ id: UUID) async -> UIImage? {
        guard let url = fileURL(for: id) else { return nil }
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
        return data.flatMap { UIImage(data: $0) }
    }

    func remove(_ id: UUID) {
        images[id] = nil
        cardPreviews[id] = nil
        loadOrder.removeAll { $0 == id }
        guard let url = fileURL(for: id) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    private func insert(_ image: UIImage, for id: UUID) {
        images[id] = image
        cardPreviews[id] = Self.cardPreview(from: image)
        loadOrder.removeAll { $0 == id }
        loadOrder.append(id)
        while loadOrder.count > Self.memoryLimit {
            images[loadOrder.removeFirst()] = nil
        }
    }

    private func save(_ image: UIImage, for id: UUID) {
        guard let directory, let url = fileURL(for: id),
              let data = image.jpegData(compressionQuality: 0.7) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).jpg")
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Shrinks the page to a few dozen pixels, then blurs it. Shrinking first
    /// averages away text and edges entirely, so what's left is smooth color;
    /// blurring a full-size page instead leaves streaks where text was.
    private static func cardPreview(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard input.extent.width > 0 else { return nil }

        let shrink = CIFilter.lanczosScaleTransform()
        shrink.inputImage = input
        shrink.scale = Float(36 / input.extent.width)
        shrink.aspectRatio = 1
        guard let small = shrink.outputImage else { return nil }

        let blurred = small
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 2.5)
            .cropped(to: small.extent)
        guard let output = ciContext.createCGImage(blurred, from: small.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(renderScale, image.scale)
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
