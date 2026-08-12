import Foundation
import NetFS

/// Wraps NetFS's synchronous mount call for classic Finder's "Connect to
/// Server…" (smb://, afp://, nfs://…). Credentials aren't collected here —
/// when a share needs auth, NetFS shows the system's own NetAuth prompt.
public enum ServerConnection {
    public enum ConnectError: Error, LocalizedError {
        case invalidAddress
        case mountFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidAddress:
                return NSLocalizedString(
                    "That doesn’t look like a server address (e.g. smb://server/share).",
                    comment: "サーバ接続: アドレスが不正なときのエラー"
                )
            case .mountFailed(let status):
                let format = NSLocalizedString(
                    "Couldn’t connect to the server (error %d).",
                    comment: "サーバ接続: マウント失敗時のエラー（%d=エラーコード）"
                )
                return String(format: format, status)
            }
        }
    }

    /// Connects to and mounts a file server. Synchronous and network-bound
    /// (NetFSMountURLSync blocks until the mount finishes, fails, or the
    /// user cancels an auth prompt) — always call this off the main thread.
    public static func connect(to addressString: String) throws -> [URL] {
        guard let url = URL(string: addressString), url.scheme != nil, url.host != nil else {
            throw ConnectError.invalidAddress
        }

        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountPoints)
        guard status == 0 else {
            throw ConnectError.mountFailed(status: status)
        }

        let paths = (mountPoints?.takeRetainedValue() as? [String]) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }
}
