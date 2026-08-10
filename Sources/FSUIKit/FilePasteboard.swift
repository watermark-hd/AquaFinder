import AppKit

/// Finder 標準の ⌘C/⌘V によるファイルのコピー＆ペースト用パスボード操作。
/// ドラッグ&ドロップ用の NSPasteboard(name: .drag) とは別に、`.general`
/// パスボードへ URL の配列を書き込み／読み出す薄いラッパー。
public enum FilePasteboard {
    public static func write(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    public static func readURLs() -> [URL] {
        let pasteboard = NSPasteboard.general
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return []
        }
        return objects
    }
}
