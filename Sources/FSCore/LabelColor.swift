import Foundation

/// Classic Finder's 7-color label system. Storage/interop lives here
/// (AppKit-free); the NSColor mapping lives in FSUIKit since that's the
/// AppKit-facing layer.
public enum LabelColor: Int, CaseIterable {
    case none = 0
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    /// ディスク上のタグ名（実 Finder のタグと相互運用するため常に英語固定）。
    /// UI表示には使わない — 表示名は `displayName` を使うこと。
    fileprivate var finderTagName: String {
        switch self {
        case .none: return "None"
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

    /// UI表示用のローカライズ名。
    public var displayName: String {
        switch self {
        case .none: return NSLocalizedString("None", comment: "ラベルカラー: なし")
        case .gray: return NSLocalizedString("Gray", comment: "ラベルカラー: グレー")
        case .green: return NSLocalizedString("Green", comment: "ラベルカラー: グリーン")
        case .purple: return NSLocalizedString("Purple", comment: "ラベルカラー: パープル")
        case .blue: return NSLocalizedString("Blue", comment: "ラベルカラー: ブルー")
        case .yellow: return NSLocalizedString("Yellow", comment: "ラベルカラー: イエロー")
        case .red: return NSLocalizedString("Red", comment: "ラベルカラー: レッド")
        case .orange: return NSLocalizedString("Orange", comment: "ラベルカラー: オレンジ")
        }
    }

    /// Writing a reserved color name as an ordinary tag is the documented,
    /// reliable way to get Finder's colored-dot label behavior through the
    /// public tagNames API. (An earlier attempt used the undocumented
    /// empty-name "\n<colorIndex>" format real Finder itself writes for a
    /// "pure color, no visible chip" look — that got silently dropped by
    /// setResourceValue's own validation, so this documented fallback,
    /// already anticipated as a real possibility in the project plan, is
    /// what's actually wired up. Trade-off: the label shows as a small
    /// named tag chip in real Finder, e.g. "Red", not a bare color dot.)
    static func from(finderTag tag: String) -> LabelColor? {
        allCases.first { $0 != .none && $0.finderTagName.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

extension FileItem {
    public var labelColor: LabelColor {
        guard let tags = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames else { return .none }
        for tag in tags {
            if let color = LabelColor.from(finderTag: tag) { return color }
        }
        return .none
    }

    public func setLabelColor(_ color: LabelColor) throws {
        var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        tags.removeAll { LabelColor.from(finderTag: $0) != nil }
        if color != .none {
            tags.append(color.finderTagName)
        }
        // Swift's URL.resourceValues is read/get-only for tagNames on this
        // SDK; NSURL's setResourceValue(_:forKey:) is the settable path,
        // and mutates the underlying file (extended attribute) regardless
        // of which URL/NSURL instance is used to reach it.
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
