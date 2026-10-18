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
        progressObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.panel.update(
                    icon: icon, itemName: item.url.lastPathComponent,
                    completedCount: (self?.index ?? 0) + 1, totalCount: self?.items.count ?? 1,
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
