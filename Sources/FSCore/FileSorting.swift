import Foundation

/// What Icon and Column view can sort by, chosen from the View menu's
/// "Arrange By" submenu — mirrors the fields List view's clickable column
/// headers already sort by, just without a header to click.
public enum FileSortField: String, CaseIterable {
    case name
    case dateModified
    case size
    case kind

    public var displayName: String {
        switch self {
        case .name: return NSLocalizedString("Name", comment: "並べ替え基準: 名前")
        case .dateModified: return NSLocalizedString("Date Modified", comment: "並べ替え基準: 変更日")
        case .size: return NSLocalizedString("Size", comment: "並べ替え基準: サイズ")
        case .kind: return NSLocalizedString("Kind", comment: "並べ替え基準: 種類")
        }
    }
}

public enum FileSorting {
    /// Folder sizes aren't known synchronously (see FileItem.fileSize's
    /// doc comment) — pass in whatever's already been calculated
    /// (List/Icon/Column each keep their own cache) and folders not yet
    /// sized sort as 0 rather than blocking on a recursive walk.
    public static func sorted(
        _ items: [FileItem],
        by field: FileSortField,
        folderSizeCache: [URL: Int64] = [:]
    ) -> [FileItem] {
        items.sorted { compare($0, $1, by: field, folderSizeCache: folderSizeCache) == .orderedAscending }
    }

    private static func compare(
        _ lhs: FileItem,
        _ rhs: FileItem,
        by field: FileSortField,
        folderSizeCache: [URL: Int64]
    ) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .dateModified:
            return compare(lhs.modificationDate ?? .distantPast, rhs.modificationDate ?? .distantPast)
        case .size:
            return compare(size(of: lhs, folderSizeCache: folderSizeCache), size(of: rhs, folderSizeCache: folderSizeCache))
        case .kind:
            return (lhs.kindDescription ?? "").localizedStandardCompare(rhs.kindDescription ?? "")
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func size(of item: FileItem, folderSizeCache: [URL: Int64]) -> Int64 {
        if item.isBrowsable {
            return folderSizeCache[item.url] ?? 0
        }
        return Int64(item.fileSize ?? 0)
    }
}
