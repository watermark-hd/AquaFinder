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

    /// 共有ボリュームのマウント元ホスト（サーバー名/IPアドレス）を返す。
    /// ローカルの「書類」フォルダ(PLACES)と、他のMacをApple ID共有で
    /// 繋いだ際に生成される同名の共有ボリューム(SHARED)が、サイドバー上
    /// では見分けが付かない、という混乱を解消するために追加した。
    /// マウント元の生パス(例: "//user@192.168.11.12/書類"や
    /// "//GUEST:@airmac/disk1_pt1")からホスト部分だけを取り出す。
    public static func remoteHost(for volumeURL: URL) -> String? {
        var buf = statfs()
        guard statfs(volumeURL.path, &buf) == 0 else { return nil }
        let mountedFrom = withUnsafeBytes(of: &buf.f_mntfromname) { raw -> String in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: pointer)
        }
        // "//user@host/share" or "//user:@host/share" の形から host だけ
        // 取り出す。ローカルディスク(例: "/dev/disk3s5")には"//"が無いので
        // その場合は共有ではないと判断してnilを返す。
        guard mountedFrom.hasPrefix("//") else { return nil }
        let afterSlashes = mountedFrom.dropFirst(2)
        guard let userAndHost = afterSlashes.split(separator: "/", maxSplits: 1).first else { return nil }
        guard let host = userAndHost.split(separator: "@").last, !host.isEmpty else { return nil }
        return String(host)
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
