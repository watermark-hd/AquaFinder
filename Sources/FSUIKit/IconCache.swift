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

    public static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
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
