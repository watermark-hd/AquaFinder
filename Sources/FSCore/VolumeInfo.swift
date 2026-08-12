import Foundation

public enum VolumeInfo {
    /// Mounted local volumes for the sidebar's "Devices" section — internal
    /// and removable disks, not network shares (see `sharedVolumes()`).
    public static func mountedVolumes() -> [FileItem] {
        volumes(local: true)
    }

    /// Mounted network shares (smb://, afp://, nfs://…) for the sidebar's
    /// "Shared" section — whatever Connect to Server has mounted, plus
    /// anything already mounted outside the app (Finder, `mount_smbfs`, …).
    public static func sharedVolumes() -> [FileItem] {
        volumes(local: false)
    }

    private static func volumes(local: Bool) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .localizedNameKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }
        return urls.filter { url in
            let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
            return isLocal == local
        }.map(FileItem.init)
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
