import Foundation

public enum FileListing {
    /// Non-recursive listing of a directory's contents, hidden files
    /// excluded, sorted the way classic Finder sorts "by Name" (localized,
    /// case-insensitive, folders and files intermixed).
    public static func contents(of directoryURL: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey, .nameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .map(FileItem.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
