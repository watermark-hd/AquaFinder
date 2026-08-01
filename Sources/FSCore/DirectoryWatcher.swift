import Foundation

/// Watches a single directory for changes using a DispatchSource file-system
/// object source (kqueue-backed). Fires `onChange` on the main queue; does
/// not diff contents itself, callers re-list on change.
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1

    public var onChange: (() -> Void)?

    public init() {}

    public func startWatching(_ url: URL) {
        stop()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        newSource.setEventHandler { [weak self] in
            self?.onChange?()
        }
        newSource.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        newSource.resume()
        source = newSource
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
