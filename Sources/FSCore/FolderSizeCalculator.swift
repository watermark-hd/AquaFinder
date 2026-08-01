import Foundation

/// Recursive folder size calculation, off the main thread and cancellable
/// — used by Get Info, which needs to show "Calculating…" then a final
/// number without blocking the UI, and stop cleanly if the panel closes
/// mid-calculation.
public final class FolderSizeCalculator {
    private var isCancelled = false

    public init() {}

    public func cancel() {
        isCancelled = true
    }

    public func calculate(_ url: URL, completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var total: Int64 = 0
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            if let enumerator {
                for case let itemURL as URL in enumerator {
                    if self?.isCancelled == true { return }
                    if let size = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        total += Int64(size)
                    }
                }
            }
            if self?.isCancelled == true { return }
            DispatchQueue.main.async {
                completion(total)
            }
        }
    }
}
