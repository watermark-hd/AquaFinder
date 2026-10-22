import AppKit
import FSCore
import FSUIKit

/// Runs a batch of copy/move operations one at a time off the main thread,
/// showing a classic-styled progress panel if the batch is still running
/// after a short delay — fast operations (small files, same-volume moves)
/// never show anything, matching real Finder's own behavior of not
/// flashing a copy window for something that finishes instantly.
///
/// Each item carries its own already-resolved operation kind, since a
/// single drop can mix copies and moves (e.g. sources on different
/// volumes dragged together) — see `FileOperations.resolveDragOperation`.
public final class TransferCoordinator {
    private let items: [(url: URL, kind: DragOperationKind)]
    private let destinationDirectory: URL
    private let completion: ([URL]) -> Void

    private var index = 0
    private var results: [URL] = []
    private var cancelled = false
    private var currentProgress: Progress?
    private var progressObservation: NSKeyValueObservation?

    /// Guards against scheduling more than one pending main-thread UI
    /// update at a time — see the comment at the KVO observation below for
    /// why this exists.
    private var isUIUpdateScheduled = false
    private let uiUpdateLock = NSLock()

    private lazy var panel = TransferProgressWindowController(kind: items.first?.kind ?? .copy)
    private var panelShown = false
    private var showPanelWorkItem: DispatchWorkItem?

    /// Keeps the coordinator alive for the duration of the batch — nothing
    /// else holds a strong reference to it once `perform` returns.
    private static var activeCoordinators: [ObjectIdentifier: TransferCoordinator] = [:]

    @discardableResult
    public static func perform(
        _ items: [(url: URL, kind: DragOperationKind)],
        into destinationDirectory: URL,
        completion: @escaping ([URL]) -> Void
    ) -> TransferCoordinator? {
        guard !items.isEmpty else {
            completion([])
            return nil
        }
        let coordinator = TransferCoordinator(items: items, destinationDirectory: destinationDirectory, completion: completion)
        activeCoordinators[ObjectIdentifier(coordinator)] = coordinator
        coordinator.start()
        return coordinator
    }

    private init(
        items: [(url: URL, kind: DragOperationKind)], destinationDirectory: URL, completion: @escaping ([URL]) -> Void
    ) {
        self.items = items
        self.destinationDirectory = destinationDirectory
        self.completion = completion
    }

    private func start() {
        panel.onCancel = { [weak self] in self?.cancelled = true }

        // Real Finder doesn't show a copy dialog for anything that finishes
        // quickly — only put the panel on screen if the batch is still
        // running half a second in.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled, self.index < self.items.count else { return }
            self.panel.showWindow(nil)
            self.panel.window?.center()
            self.panelShown = true
        }
        showPanelWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)

        processNext()
    }

    private func processNext() {
        guard index < items.count, !cancelled else {
            finish()
            return
        }

        let item = items[index]
        let icon = IconCache.icon(for: item.url)
        panel.update(
            icon: icon, itemName: item.url.lastPathComponent,
            completedCount: index + 1, totalCount: items.count, fraction: 0
        )

        let handleResult: (Result<URL, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            if case .success(let destination) = result {
                self.results.append(destination)
            }
            self.progressObservation = nil
            self.currentProgress = nil
            self.index += 1
            self.processNext()
        }

        let progress: Progress
        switch item.kind {
        case .copy:
            progress = FileOperations.copyAsync(item.url, into: destinationDirectory, completion: handleResult)
        case .move:
            progress = FileOperations.moveAsync(item.url, into: destinationDirectory, completion: handleResult)
        }
        currentProgress = progress
        // `copyFileWithProgress` updates `completedUnitCount` after every
        // 4MB chunk, which on a fast internal SSD can fire far faster than
        // the main thread can actually draw a frame — an earlier version
        // of this unconditionally dispatched a new main-thread block per
        // KVO firing, and a real 84GB copy backed up tens of thousands of
        // those faster than AppKit could drain them, ballooning the app to
        // 60+GB of resident memory and bringing down the whole system.
        // Coalesce instead: at most one update is ever in flight, and
        // because `progress` is a reference type, the block that finally
        // runs always reads whatever the *current* fraction is at that
        // point — never a stale value from when it was scheduled — so
        // throttling the redraw rate doesn't throttle progress accuracy.
        progressObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self else { return }
            self.uiUpdateLock.lock()
            let alreadyScheduled = self.isUIUpdateScheduled
            self.isUIUpdateScheduled = true
            self.uiUpdateLock.unlock()
            guard !alreadyScheduled else { return }

            DispatchQueue.main.async {
                self.uiUpdateLock.lock()
                self.isUIUpdateScheduled = false
                self.uiUpdateLock.unlock()
                self.panel.update(
                    icon: icon, itemName: item.url.lastPathComponent,
                    completedCount: self.index + 1, totalCount: self.items.count,
                    fraction: progress.fractionCompleted
                )
            }
        }
    }

    private func finish() {
        showPanelWorkItem?.cancel()
        if panelShown {
            panel.close()
        }
        currentProgress?.cancel()
        let finalResults = results
        completion(finalResults)
        TransferCoordinator.activeCoordinators.removeValue(forKey: ObjectIdentifier(self))
    }
}
