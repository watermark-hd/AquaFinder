import AppKit
import FSCore
import FSUIKit

public final class IconViewController: NSViewController {
    public var onOpen: ((URL) -> Void)?
    /// Fired after this view performs a rename or drag copy/move — lets
    /// MainWindowController refresh sibling views (Column/List, or the
    /// pane a sidebar drop's *source* items lived in) that this view has
    /// no reference to and can't refresh itself.
    public var onFileSystemChange: (() -> Void)?
    /// Fired when "Get Info" is chosen from the right-click menu — opening
    /// the actual panel is MainWindowController's job (it owns the set of
    /// open Get Info windows), this view just reports the request.
    public var onShowInfo: ((FileItem) -> Void)?
    /// Fired when "Open in New Window" is chosen from the right-click menu
    /// on a folder — MainWindowController delegates the actual window
    /// creation to AppDelegate.
    public var onOpenInNewWindow: ((FileItem) -> Void)?
    /// Fired on any selection change — MainWindowController uses this to
    /// keep an open Quick Look panel in sync without caring which view
    /// mode is actually active.
    public var onSelectionChange: (() -> Void)?

    /// How many icons currently fit per row — MainWindowController uses
    /// this so Quick Look's Up/Down arrow-key stepping can move by a full
    /// row (matching a real icon grid) instead of by a single item like
    /// Left/Right does.
    public var itemsPerRow: Int {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout,
              layout.itemSize.width > 0
        else { return 1 }
        let availableWidth = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
        let stride = layout.itemSize.width + layout.minimumInteritemSpacing
        return max(1, Int((availableWidth + layout.minimumInteritemSpacing) / stride))
    }

    private let collectionView = ContextMenuCollectionView()
    private let scrollView = NSScrollView()
    private var items: [FileItem] = []
    private var rootURL: URL
    private var textSize: TextSize = AppearancePreferenceStore.textSize

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("IconItem")
    private let dragModifierTracker = DragModifierTracker()
    private let springLoadTimer = SpringLoadTimer()

    // NSCollectionView has no target/doubleAction like NSTableView, so
    // double-click is detected via a click gesture recognizer instead.
    private lazy var doubleClickGesture: NSClickGestureRecognizer = {
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        gesture.numberOfClicksRequired = 2
        // By default a gesture recognizer withholds the underlying mouse
        // events from the view until it's decided whether this click
        // sequence matches its gesture — which was delaying ordinary
        // single-click selection by the system's whole double-click
        // window (~0.5–1s) waiting to see if a second click would follow.
        // This lets clicks reach normal selection handling immediately;
        // double-click detection still happens independently.
        gesture.delaysPrimaryMouseButtonEvents = false
        return gesture
    }()

    public init(rootURL: URL) {
        self.rootURL = rootURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = NSView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setUpCollectionView()
        reload()
        springLoadTimer.onActivate = { [weak self] url in
            self?.onOpen?(url)
        }
    }

    public func setRoot(_ url: URL) {
        rootURL = url
        reload()
    }

    public func applyTextSize(_ textSize: TextSize) {
        self.textSize = textSize
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            let itemSize = textSize.gridItemSize
            layout.itemSize = NSSize(width: itemSize.width, height: itemSize.height)
            layout.invalidateLayout()
        }
        collectionView.reloadData()
    }

    private func reload() {
        items = DirectoryListingCache.contents(of: rootURL)
        collectionView.reloadData()
    }

    private func setUpCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        let itemSize = textSize.gridItemSize
        layout.itemSize = NSSize(width: itemSize.width, height: itemSize.height)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(IconCollectionViewItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.addGestureRecognizer(doubleClickGesture)
        collectionView.registerForDraggedTypes([.fileURL])
        // Both must be set explicitly — see the matching comment in
        // ListViewController for why "local" drags need their own call.
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.menuProvider = { [weak self] indexPath in
            self?.contextMenu(at: indexPath)
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        let fileItem = items[indexPath.item]
        if fileItem.isBrowsable {
            onOpen?(fileItem.url)
        } else {
            NSWorkspace.shared.open(fileItem.url)
        }
    }

    fileprivate func commitRename(_ fileItem: FileItem, to newName: String) {
        guard newName != fileItem.name else { return }
        _ = try? FileOperations.rename(fileItem.url, to: newName)
        reload()
        onFileSystemChange?()
    }

    private func contextMenu(at indexPath: IndexPath?) -> NSMenu? {
        guard let indexPath, indexPath.item < items.count else { return nil }
        let fileItem = items[indexPath.item]
        if !collectionView.selectionIndexPaths.contains(indexPath) {
            collectionView.selectionIndexPaths = [indexPath]
        }
        let menu = NSMenu()
        let menuItems = FileContextMenu.items(
            for: fileItem,
            onGetInfo: { [weak self] in self?.onShowInfo?(fileItem) },
            onRename: { [weak self] in self?.beginRename() },
            onDuplicate: { [weak self] in
                _ = try? FileOperations.duplicate(fileItem.url)
                self?.reload()
                self?.onFileSystemChange?()
            },
            onMoveToTrash: { [weak self] in
                _ = try? FileOperations.moveToTrash(fileItem.url)
                self?.reload()
                self?.onFileSystemChange?()
            },
            onSetLabelColor: { [weak self] color in
                do {
                    try fileItem.setLabelColor(color)
                } catch {
                    NSLog("AquaFinder: setLabelColor failed: \(error)")
                }
                self?.reload()
                self?.onFileSystemChange?()
            },
            onOpenInNewWindow: { [weak self] in self?.onOpenInNewWindow?(fileItem) }
        )
        menuItems.forEach { menu.addItem($0) }
        return menu
    }
}

/// NSCollectionView has no NSMenuDelegate-driven "which item was clicked"
/// hook the way NSTableView does; overriding `menu(for:)` directly gives
/// us the click location to hit-test against.
final class ContextMenuCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(indexPathForItem(at: point))
    }
}

extension IconViewController: SelectionProviding {
    public var selectedURLs: [URL] {
        collectionView.selectionIndexPaths.map { items[$0.item].url }
    }

    /// Icon view always shows a flat listing of `rootURL`, same as List
    /// view — no per-column ambiguity the way Column view has.
    public var currentDirectoryURL: URL { rootURL }

    public func refresh() {
        reload()
    }

    public func beginRename() {
        guard let indexPath = collectionView.selectionIndexPaths.first,
              let item = collectionView.item(at: indexPath) as? IconCollectionViewItem
        else { return }
        item.beginEditing()
    }

    public func selectItem(at url: URL) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
    }
}

extension IconViewController: NSCollectionViewDataSource {
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        guard let iconItem = item as? IconCollectionViewItem else { return item }
        iconItem.configure(with: items[indexPath.item], textSize: textSize)
        iconItem.onCommitRename = { [weak self] fileItem, newName in
            self?.commitRename(fileItem, to: newName)
        }
        return iconItem
    }

    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items[indexPath.item].url as NSURL
    }
}

extension IconViewController: NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
        let index = proposedDropIndexPath.pointee.item
        if proposedDropOperation.pointee == .on, index < items.count, !items[index].isBrowsable {
            // Can't drop onto a regular file, only into folders or empty space.
            return []
        }
        // validateDrop fires repeatedly as the mouse moves during the
        // drag, so this is where we reliably catch the Option/⌘ state —
        // see DragModifierTracker's doc comment for why.
        dragModifierTracker.sample()

        if proposedDropOperation.pointee == .on, index < items.count, items[index].isBrowsable {
            springLoadTimer.hover(target: items[index].url)
        } else {
            springLoadTimer.cancel()
        }

        return [.copy, .move]
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        springLoadTimer.cancel()
        let destinationDirectory: URL
        if dropOperation == .on, indexPath.item < items.count, items[indexPath.item].isBrowsable {
            destinationDirectory = items[indexPath.item].url
        } else {
            destinationDirectory = rootURL
        }
        guard let sourceURLs = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return false }

        for sourceURL in sourceURLs {
            let operation = dragModifierTracker.resolve(source: sourceURL, destinationDirectory: destinationDirectory)
            _ = try? (operation == .copy
                ? FileOperations.copy(sourceURL, into: destinationDirectory)
                : FileOperations.move(sourceURL, into: destinationDirectory))
        }
        reload()
        onFileSystemChange?()
        return true
    }
}
