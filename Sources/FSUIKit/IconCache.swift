import AppKit

/// `NSWorkspace.icon(forFile:)` is slow enough (Launch Services lookups)
/// that calling it uncached on every cell/item configuration — which
/// happens repeatedly during reloads and scrolling, not just once per
/// visible row — was the main cause of the whole app feeling sluggish,
/// especially on slower Intel Macs where each lookup takes noticeably
/// longer. Every view that shows a file icon should go through this
/// instead of calling NSWorkspace directly.
///
/// Backed by `NSCache` rather than a plain dictionary so
/// `DirectoryListingCache`'s background prefetch (see its doc comment)
/// can safely warm this from a background queue at the same time a view
/// is reading it on the main thread — a plain `[String: NSImage]` isn't
/// safe under that kind of concurrent access.
public enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    // A generic icon lookup by UTI (not tied to any one file) is a cheap,
    // local operation — unlike icon(forFile:), it never has to touch the
    // filesystem the file itself lives on, so it stays fast even when
    // that's a slow network mount. Used as the instant placeholder below.
    private static let genericIcon = NSWorkspace.shared.icon(forFileType: "public.data")

    public static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// Same lookup, but never blocks the caller on a slow volume (a NAS
    /// mount over a weak network link, for instance) — `icon(for:)`'s
    /// direct `NSWorkspace.icon(forFile:)` call does real I/O against
    /// wherever the file actually lives, so a slow mount means a slow,
    /// main-thread-blocking call. `completion` fires synchronously with
    /// a generic placeholder first if nothing's cached yet (or just once,
    /// synchronously, with the real icon if it's already cached), then
    /// again on the main thread with the real icon once the (backgrounded)
    /// lookup finishes — the same "placeholder, then upgrade" shape
    /// `ThumbnailLoader` already uses for real content thumbnails.
    public static func icon(for url: URL, completion: @escaping (NSImage) -> Void) {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        completion(genericIcon)
        DispatchQueue.global(qos: .userInitiated).async {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            DispatchQueue.main.async {
                cache.setObject(icon, forKey: key)
                completion(icon)
            }
        }
    }

    /// Warms the cache for a batch of URLs off the main thread. Wired up
    /// (see `DirectoryListingCache.onNewListing` in FSCore) to run right
    /// after any folder is listed, so that by the time Icon/List/Column
    /// view actually asks for these icons — as the user scrolls, not all
    /// at once — most calls already hit the cache instead of blocking the
    /// main thread on a fresh Launch Services lookup. Purely a warm-up:
    /// safe to call redundantly, and `icon(for:)` still works correctly
    /// (just synchronously) for anything this hasn't gotten to yet.
    public static func prefetch(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                _ = icon(for: url)
            }
        }
    }
}
