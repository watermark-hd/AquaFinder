import AppKit

/// `NSWorkspace.icon(forFile:)` is slow enough (Launch Services lookups)
/// that calling it uncached on every cell/item configuration — which
/// happens repeatedly during reloads and scrolling, not just once per
/// visible row — was the main cause of the whole app feeling sluggish.
/// Every view that shows a file icon should go through this instead of
/// calling NSWorkspace directly.
public enum IconCache {
    private static var cache: [String: NSImage] = [:]

    public static func icon(for url: URL) -> NSImage {
        if let cached = cache[url.path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = icon
        return icon
    }
}
