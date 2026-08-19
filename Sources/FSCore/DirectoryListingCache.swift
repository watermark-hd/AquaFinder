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

    public static func invalidate(_ directoryURL: URL) {
        cache.removeValue(forKey: directoryURL)
    }

    public static func invalidateAll() {
        cache.removeAll()
    }
}
