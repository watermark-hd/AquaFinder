import Foundation

/// Watches a single directory for changes using a DispatchSource file-system
/// object source (kqueue-backed). Fires `onChange` on the main queue; does
/// not diff contents itself, callers re-list on change.
///
/// Raw kqueue `.write` events fire once *per file changed inside the
/// directory*, not once per "the folder changed" — a background sync tool
/// (Dropbox, Creative Cloud, …) touching several files, or a slow network
/// share where the OS's own directory-change bookkeeping is chattier,
/// can raise a burst of dozens of events for what a user perceives as one
/// change. Without coalescing that into a single reload, callers (this
/// app included) end up running a full listing-invalidate-and-reload
/// cycle back-to-back that many times — each one individually correct,
/// but interrupted by the next before it's had a chance to settle. Against
/// `NSOutlineView` in particular (List view keeps expanded subfolders'
/// rows around across a reload) that showed up as rows briefly
/// duplicating and then "healing" one reload pass at a time, rather than
/// updating cleanly all at once. Debouncing so `onChange` only actually
/// fires once the burst has gone quiet for `debounceInterval` fixes that
/// at the source, rather than trying to make every downstream reload
/// consumer defensive against overlapping reloads individually.
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingChange: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    public var onChange: (() -> Void)?

    public init(debounceInterval: TimeInterval = 0.3) {
        self.debounceInterval = debounceInterval
    }

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
            self?.scheduleDebouncedChange()
        }
        newSource.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        newSource.resume()
        source = newSource
    }

    private func scheduleDebouncedChange() {
        // Each new event pushes the deadline back out — onChange only
        // actually fires once `debounceInterval` has passed with no
        // further events, collapsing an entire burst into one reload.
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    public func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
