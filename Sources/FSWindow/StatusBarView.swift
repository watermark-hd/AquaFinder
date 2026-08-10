import AppKit
import FSUIKit

/// Bottom status bar: "N items, X GB available" — matches what real
/// Finder shows, using the same `.volumeAvailableCapacityForImportantUsage`
/// figure it does (accounts for purgeable/APFS space) rather than the
/// older, less accurate `.volumeAvailableCapacity`.
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // システムのマテリアル（ダークモード時に黒く見えることがある）に頼らず、
        // 常に自前で背景を塗る（内容は applyTheme で設定）。
        wantsLayer = true

        label.font = NSFont.systemFont(ofSize: TextSize.medium.baseFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ theme: AppTheme) {
        switch theme {
        case .graphite10_6:
            layer?.backgroundColor = NSColor(calibratedWhite: 0.80, alpha: 1.0).cgColor
        case .metal10_4:
            layer?.backgroundColor = MetalTexture.backgroundColor.cgColor
        }
    }

    func applyTextSize(_ textSize: TextSize) {
        label.font = NSFont.systemFont(ofSize: textSize.baseFontSize)
    }

    func update(itemCount: Int, directoryURL: URL) {
        var statsText: String
        if itemCount == 1 {
            statsText = NSLocalizedString("1 item", comment: "ステータスバー: 項目数（1件のとき）")
        } else {
            let format = NSLocalizedString("%d items", comment: "ステータスバー: 項目数（複数件のとき、%dは件数）")
            statsText = String(format: format, itemCount)
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if let capacity = (try? directoryURL.resourceValues(forKeys: keys))?.volumeAvailableCapacityForImportantUsage {
            let availableFormat = NSLocalizedString("%1$@, %2$@ available", comment: "ステータスバー: 項目数と空き容量の連結（%1$@=項目数の文言, %2$@=空き容量）")
            statsText = String(format: availableFormat, statsText, ByteCountFormatter.statusBar.string(fromByteCount: capacity))
        }

        let pathFormat = NSLocalizedString("%1$@ — %2$@", comment: "ステータスバー: フルパスと項目数/空き容量の連結（%1$@=現在のフォルダのパス, %2$@=項目数と空き容量の文言）")
        label.stringValue = String(format: pathFormat, Self.displayPath(for: directoryURL), statsText)
    }

    /// ホームディレクトリ配下は "~" に短縮したフルパス表示（ステータスバーの
    /// 限られた幅で読みやすくするため）。
    private static func displayPath(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private extension ByteCountFormatter {
    static let statusBar: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
