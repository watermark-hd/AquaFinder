import Foundation

/// UI 全体の文字サイズ・行の高さ・アイコンサイズの3段階プリセット。
/// 老眼でも読みやすいよう、以前より全体的に大きめに設定してある
/// （旧「大」相当が新しい「中」になるくらいのスケール、「大」はさらに拡大）。
public enum TextSize: Int, CaseIterable {
    case small = 0
    case medium = 1
    case large = 2

    public var baseFontSize: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 15
        case .large: return 19
        }
    }

    /// リスト表示（ファイル一覧）の行の高さ。
    public var listRowHeight: CGFloat {
        switch self {
        case .small: return 20
        case .medium: return 26
        case .large: return 34
        }
    }

    /// サイドバーの行の高さ。
    public var sidebarRowHeight: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 28
        case .large: return 36
        }
    }

    /// サイドバー／リスト表示の行アイコン（ファイル/フォルダアイコン）の
    /// 一辺のサイズ。
    public var rowIconSize: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 20
        case .large: return 26
        }
    }

    /// アイコン表示のアイコン画像の一辺のサイズ。
    public var gridIconSize: CGFloat {
        switch self {
        case .small: return 40
        case .medium: return 56
        case .large: return 76
        }
    }

    /// アイコン表示の1セル分のサイズ（アイコン＋ラベル込み）。
    public var gridItemSize: (width: CGFloat, height: CGFloat) {
        switch self {
        case .small: return (84, 78)
        case .medium: return (108, 104)
        case .large: return (140, 136)
        }
    }

    public var displayName: String {
        switch self {
        case .small: return NSLocalizedString("Small", comment: "文字サイズ設定: 小")
        case .medium: return NSLocalizedString("Medium", comment: "文字サイズ設定: 中")
        case .large: return NSLocalizedString("Large", comment: "文字サイズ設定: 大")
        }
    }
}

/// ウィンドウ全体の見た目のテーマ。
public enum AppTheme: String, CaseIterable {
    /// 10.6 Snow Leopard 風：明るいグレーの統一ツールバー（現行の見た目）。
    case graphite10_6
    /// 10.4 Tiger 風：ブラッシュドメタル調。
    case metal10_4

    public var displayName: String {
        switch self {
        case .graphite10_6: return NSLocalizedString("Graphite (10.6)", comment: "テーマ設定: 10.6風グラファイト")
        case .metal10_4: return NSLocalizedString("Brushed Metal (10.4)", comment: "テーマ設定: 10.4風ブラッシュドメタル")
        }
    }
}

extension Notification.Name {
    /// テーマまたは文字サイズが変更されたときに発火。開いている全ウィンドウ
    /// はこれを購読して即座に見た目を更新する。
    public static let appearancePreferencesDidChange = Notification.Name("AquaFinder.appearancePreferencesDidChange")
    /// 環境設定パネルの「ウィンドウサイズを既定に戻す」ボタンから発火。
    /// 開いている全ウィンドウがこれを購読し、自分自身のサイズ／サイドバー
    /// 幅を既定値にリセットする。
    public static let resetWindowLayoutRequested = Notification.Name("AquaFinder.resetWindowLayoutRequested")
}

/// `ViewModePreferenceStore` と同じ、Application Support 配下の plist への
/// 永続化パターンを流用する。
public enum AppearancePreferenceStore {
    private static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("AquaFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AppearancePreferences.plist")
    }

    private static func loadPlist() -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return [:]
        }
        return plist
    }

    public static var textSize: TextSize {
        get {
            guard let rawValue = loadPlist()["textSize"] as? Int, let size = TextSize(rawValue: rawValue) else {
                return .medium
            }
            return size
        }
        set {
            var plist = loadPlist()
            plist["textSize"] = newValue.rawValue
            write(plist)
        }
    }

    public static var theme: AppTheme {
        get {
            guard let rawValue = loadPlist()["theme"] as? String, let theme = AppTheme(rawValue: rawValue) else {
                return .graphite10_6
            }
            return theme
        }
        set {
            var plist = loadPlist()
            plist["theme"] = newValue.rawValue
            write(plist)
        }
    }

    private static func write(_ plist: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: fileURL)
        NotificationCenter.default.post(name: .appearancePreferencesDidChange, object: nil)
    }
}
