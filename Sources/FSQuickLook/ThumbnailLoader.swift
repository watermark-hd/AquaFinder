import AppKit
import Quartz
import QuickLookThumbnailing

/// Real content thumbnails (image contents, PDF first page, etc.) for
/// Icon View, upgrading past the generic per-UTI icons `IconCache` gives
/// out. Loading is asynchronous — callers should already be showing the
/// generic icon as a placeholder and swap it out when `completion` fires.
public enum ThumbnailLoader {
    private static var cache: [URL: NSImage] = [:]

    /// Returns the underlying request so the caller can cancel it (see
    /// `cancel(_:)`) if the item it was for gets recycled before it
    /// finishes — nil when served straight from the cache, since there's
    /// nothing in flight to cancel.
    @discardableResult
    public static func thumbnail(for url: URL, size: CGSize, scale: CGFloat, completion: @escaping (NSImage) -> Void) -> QLThumbnailGenerator.Request? {
        if let cached = cache[url] {
            completion(cached)
            return nil
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            guard let representation, error == nil else { return }
            let image = NSImage(cgImage: representation.cgImage, size: size)
            DispatchQueue.main.async {
                cache[url] = image
                completion(image)
            }
        }
        return request
    }

    /// Callers (see `IconCollectionViewItem`) should call this when the
    /// cell a request was for gets reused for a different item before the
    /// original request finished, so the actual (CPU-heavy) generation
    /// work stops instead of continuing to run for an item nothing shows
    /// anymore. Matters most during a fast scroll fling on slower Macs,
    /// where dozens of these can otherwise pile up on background threads
    /// competing with the UI thread for CPU time.
    public static func cancel(_ request: QLThumbnailGenerator.Request) {
        QLThumbnailGenerator.shared.cancel(request)
    }
}
