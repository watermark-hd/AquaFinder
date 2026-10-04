import AppKit
import Quartz
import QuickLookThumbnailing

/// Real content thumbnails (image contents, PDF first page, etc.) for
/// Icon View, upgrading past the generic per-UTI icons `IconCache` gives
/// out. Loading is asynchronous — callers should already be showing the
/// generic icon as a placeholder and swap it out when `completion` fires.
public enum ThumbnailLoader {
    private static var cache: [URL: NSImage] = [:]
    // Same hazard DirectoryListingCache had (see its own doc comment): a
    // plain dictionary written to from inside an async completion handler.
    // The write below is correctly hopped to the main thread already, but
    // QLThumbnailGenerator's completion queue isn't contractually
    // guaranteed, and this cache is now read from three view controllers'
    // cell-configuration paths (Icon/List/Column) instead of just one —
    // cheap insurance against the same corrupted-pointer crash recurring
    // here instead.
    private static let lock = NSLock()

    /// Returns the underlying request so the caller can cancel it (see
    /// `cancel(_:)`) if the item it was for gets recycled before it
    /// finishes — nil when served straight from the cache, since there's
    /// nothing in flight to cancel.
    @discardableResult
    public static func thumbnail(for url: URL, size: CGSize, scale: CGFloat, completion: @escaping (NSImage) -> Void) -> QLThumbnailGenerator.Request? {
        lock.lock()
        let cachedNow = cache[url]
        lock.unlock()
        if let cachedNow {
            completion(cachedNow)
            return nil
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            guard let representation, error == nil else { return }
            // QLThumbnailGenerator fits the source into `size` preserving
            // its own aspect ratio — a landscape photo comes back as a
            // wide-but-short CGImage, not a square one. Declaring the
            // NSImage's size as the (square) requested `size` regardless
            // of the CGImage's real pixel dimensions told NSImageView
            // the image itself WAS square, so `.scaleProportionallyUpOrDown`
            // stretched a landscape photo to fill a square cell instead of
            // letterboxing it. Using the CGImage's actual pixel size
            // (divided by `scale` back to points) keeps the real aspect
            // ratio intact.
            let cgImage = representation.cgImage
            let imageSize = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            let image = NSImage(cgImage: cgImage, size: imageSize)
            DispatchQueue.main.async {
                lock.lock()
                cache[url] = image
                lock.unlock()
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
