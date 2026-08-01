import Foundation

/// Minimal spring-loaded-folder timer. `validateDrop` (or its
/// NSCollectionView/NSOutlineView equivalents) already fires repeatedly
/// while a drag hovers over a view, so call `hover(target:)` from there
/// with whatever folder URL is currently under the cursor; after ~0.75s
/// hovering the *same* target without it changing, `onActivate` fires
/// once. Call `cancel()` when the drop completes (or, best-effort, when
/// the hover moves to something that isn't a valid target).
public final class SpringLoadTimer {
    private var timer: Timer?
    private var target: URL?

    public var onActivate: ((URL) -> Void)?

    public init() {}

    public func hover(target newTarget: URL) {
        guard newTarget != target else { return }
        cancel()
        target = newTarget
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { [weak self] _ in
            guard let self, let target = self.target else { return }
            self.onActivate?(target)
            self.cancel()
        }
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}
