import Foundation

enum ViewMode: Int {
    case icon = 0
    case list = 1
    case column = 2
}

/// Persists the last-used view mode to our own plist under Application
/// Support — deliberately not `.DS_Store` (undocumented binary format,
/// real risk of corrupting the real Finder's own per-folder view state).
enum ViewModePreferenceStore {
    private static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("AquaFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ViewPreferences.plist")
    }

    static func loadViewMode() -> ViewMode {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let rawValue = plist["viewMode"] as? Int,
              let mode = ViewMode(rawValue: rawValue)
        else {
            return .column
        }
        return mode
    }

    static func saveViewMode(_ mode: ViewMode) {
        let plist: [String: Any] = ["viewMode": mode.rawValue]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: fileURL)
    }
}
