import Foundation

/// `FileListing.contents(of:)` の結果をディレクトリ単位でキャッシュする共有
/// ストア。以前は Icon/List/Column の各ビューコントローラがそれぞれ独立に
/// 同じ辞書パターンを持っていたため、1回のナビゲーションで同じフォルダの
/// 列挙・ソートが（3ビュー分＋ステータスバーの件数取得で）最大4重に走って
/// いた。これを一箇所に集約し、体感の鈍さの主因だった重複ディスクI/Oを
/// 削減する。
public enum DirectoryListingCache {
    private static var cache: [URL: [FileItem]] = [:]

    public static func contents(of directoryURL: URL) -> [FileItem] {
        if let cached = cache[directoryURL] { return cached }
        let result = FileListing.contents(of: directoryURL)
        cache[directoryURL] = result
        return result
    }

    public static func invalidate(_ directoryURL: URL) {
        cache.removeValue(forKey: directoryURL)
    }

    public static func invalidateAll() {
        cache.removeAll()
    }
}
