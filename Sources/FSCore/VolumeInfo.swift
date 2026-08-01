import Foundation

public enum VolumeInfo {
    /// Mounted volumes for the sidebar's "Devices" section, matching
    /// Snow Leopard's grouping (no "Shared"/network browsing section yet —
    /// that's part of the deferred Connect-to-Server work).
    public static func mountedVolumes() -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .localizedNameKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }
        return urls.map(FileItem.init)
    }
}

public enum WellKnownLocations {
    /// Fixed "Places" shortcuts, matching Snow Leopard's sidebar (predates
    /// the Big Sur "Favorites" reshuffle) — Home, Desktop, Documents,
    /// Applications.
    public static func places() -> [FileItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var urls = [home]
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            urls.append(desktop)
        }
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(documents)
        }
        urls.append(URL(fileURLWithPath: "/Applications"))
        return urls.map(FileItem.init)
    }
}
