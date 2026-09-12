import Foundation

/// `FileListing.contents(of:)` の結果をディレクトリ単位でキャッシュする共有
/// ストア。以前は Icon/List/Column の各ビューコントローラがそれぞれ独立に
/// 同じ辞書パターンを持っていたため、1回のナビゲーションで同じフォルダの
/// 列挙・ソートが（3ビュー分＋ステータスバーの件数取得で）最大4重に走って
/// いた。これを一箇所に集約し、体感の鈍さの主因だった重複ディスクI/Oを
/// 削減する。
public enum DirectoryListingCache {
    private static var cache: [URL: [FileItem]] = [:]

    /// FSCore doesn't depend on FSUIKit, so it can't call `IconCache`
    /// directly — the app wires this up once at launch instead (see
    /// AppDelegate) to warm `IconCache` for every folder as soon as it's
    /// listed, well before Icon/List/Column view's own cell configuration
    /// would otherwise hit a cold cache on the main thread. Left unset,
    /// this is simply a no-op.
    public static var onNewListing: (([FileItem]) -> Void)?

    public static func contents(of directoryURL: URL) -> [FileItem] {
        if let cached = cache[directoryURL] {
            onNewListing?(cached)
            return cached
        }
        let result = FileListing.contents(of: directoryURL)
        cache[directoryURL] = result
        onNewListing?(result)
        return result
    }

    /// Same as `contents(of:)`, but does the actual disk enumeration
    /// (`FileListing.contents(of:)`) on a background queue instead of
    /// blocking the caller — the synchronous version above still exists
    /// because `ColumnBrowserViewController`'s `NSBrowser` and
    /// `ListViewController`'s expanded-subfolder rows are both driven by
    /// `NSOutlineView`/`NSBrowser` data source methods that must return a
    /// value immediately and have no async equivalent. Icon/List view's
    /// own *root*-level listing and the status bar's item count don't have
    /// that constraint, so they use this instead.
    ///
    /// A cache hit still calls `completion` synchronously, on the calling
    /// thread — re-visiting an already-listed folder should feel exactly
    /// as instant as it did before, not gain an artificial round trip
    /// through the background queue.
    public static func contents(of directoryURL: URL, completion: @escaping ([FileItem]) -> Void) {
        if let cached = cache[directoryURL] {
            onNewListing?(cached)
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FileListing.contents(of: directoryURL)
            DispatchQueue.main.async {
                // Another caller may have already listed (and cached) the
                // same directory while this background listing was still
                // running — prefer whatever's already cached so concurrent
                // callers converge on one shared value instead of each
                // silently overwriting the other's.
                let resolved = cache[directoryURL] ?? result
                cache[directoryURL] = resolved
                onNewListing?(resolved)
                completion(resolved)
            }
        }
    }

    public static func invalidate(_ directoryURL: URL) {
        cache.removeValue(forKey: directoryURL)
    }

    public static func invalidateAll() {
        cache.removeAll()
    }
}
