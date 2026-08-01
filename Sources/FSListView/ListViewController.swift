import AppKit
import FSCore
import FSUIKit

/// Classic Finder's hierarchical List View: flat listing of the current
/// folder, with disclosure triangles to peek into subfolders inline
/// (NSOutlineView's native expand/collapse) without changing what the
/// window considers its "current" folder. Double-clicking a folder does
/// change the current folder, via `onOpen`; double-clicking a regular file
/// opens it with its default application.
public final class ListViewController: NSViewController {
    public var onOpen: ((URL) -> Void)?
    /// Fired after this view performs a rename or drag copy/move — lets
    /// MainWindowController refresh sibling views (Column/Icon, or the
    /// pane a sidebar drop's *source* items lived in) that this view has
    /// no reference to and can't refresh itself.
    public var onFileSystemChange: (() -> Void)?
    /// Fired when "Get Info" is chosen from the right-click menu — opening
    /// the actual panel is MainWindowController's job (it owns the set of
    /// open Get Info windows), this view just reports the request.
    public var onShowInfo: ((FileItem) -> Void)?
    /// Fired on any selection change — MainWindowController uses this to
    /// keep an open Quick Look panel in sync without caring which view
    /// mode is actually active.
    public var onSelectionChange: (() -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var rootURL: URL
    private static let labelDotTag = 998

    /// When non-nil, the outline shows this flat list instead of
    /// `rootURL`'s contents — how search results get displayed (Phase 4
    /// scopes search results to List View only; see MainWindowController).
    private var searchResults: [FileItem]?

    // NSOutlineView calls numberOfChildrenOfItem/child(_:ofItem:) many
    // times per directory during a single reload/expand/scroll pass —
    // without this cache, every one of those re-hit the disk and re-sorted
    // the folder's contents, which was the main cause of the app feeling
    // sluggish. Cleared whenever the tree can actually have changed.
    private var childrenCache: [URL: [FileItem]] = [:]
    private let dragModifierTracker = DragModifierTracker()
    private let springLoadTimer = SpringLoadTimer()

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
        setUpOutlineView()
        outlineView.reloadData()
        springLoadTimer.onActivate = { [weak self] url in
            self?.onOpen?(url)
        }
    }

    public func setRoot(_ url: URL) {
        rootURL = url
        childrenCache.removeAll()
        outlineView.reloadData()
    }

    /// Replaces the listing with a flat set of search results (no
    /// expand/collapse — matches how Spotlight results behave in Finder's
    /// own list view during an active search).
    public func showSearchResults(_ items: [FileItem]) {
        searchResults = items
        outlineView.reloadData()
    }

    public func clearSearchResults() {
        searchResults = nil
        outlineView.reloadData()
    }

    private func setUpOutlineView() {
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = "Name"
        nameColumn.width = 260

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DateModified"))
        dateColumn.title = "Date Modified"
        dateColumn.width = 150

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Kind"))
        kindColumn.title = "Kind"
        kindColumn.width = 120

        [nameColumn, dateColumn, sizeColumn, kindColumn].forEach { outlineView.addTableColumn($0) }
        outlineView.outlineTableColumn = nameColumn
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 18
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.registerForDraggedTypes([.fileURL])
        // Both must be set explicitly — "local" (within this app, e.g.
        // dragging onto our own sidebar) and "non-local" (into another
        // app) default to different, more restrictive masks otherwise,
        // which silently drops .copy even when validateDrop/acceptDrop
        // both agree Option was held.
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    @objc private func handleDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0, let fileItem = outlineView.item(atRow: row) as? FileItem else { return }
        if fileItem.isBrowsable {
            onOpen?(fileItem.url)
        } else {
            NSWorkspace.shared.open(fileItem.url)
        }
    }

    private func children(of url: URL) -> [FileItem] {
        if let cached = childrenCache[url] { return cached }
        let result = FileListing.contents(of: url)
        childrenCache[url] = result
        return result
    }
}

extension ListViewController: SelectionProviding {
    public var selectedURLs: [URL] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }.map(\.url)
    }

    /// List view always shows a flat listing of `rootURL`, so unlike
    /// Column view there's no ambiguity about "which directory" new items
    /// belong in — it's always the folder currently being browsed.
    public var currentDirectoryURL: URL { rootURL }

    public func refresh() {
        childrenCache.removeAll()
        outlineView.reloadData()
    }

    public func beginRename() {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let nameColumnIndex = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("Name"))
        guard nameColumnIndex >= 0 else { return }
        outlineView.editColumn(nameColumnIndex, row: row, with: nil, select: true)
    }

    public func selectItem(at url: URL) {
        for row in 0..<outlineView.numberOfRows {
            guard (outlineView.item(atRow: row) as? FileItem)?.url == url else { continue }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            return
        }
    }
}

extension ListViewController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let fileItem = outlineView.item(atRow: row) as? FileItem else { return }
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let items = FileContextMenu.items(
            for: fileItem,
            onGetInfo: { [weak self] in self?.onShowInfo?(fileItem) },
            onRename: { [weak self] in self?.beginRename() },
            onDuplicate: { [weak self] in
                _ = try? FileOperations.duplicate(fileItem.url)
                self?.refresh()
                self?.onFileSystemChange?()
            },
            onMoveToTrash: { [weak self] in
                _ = try? FileOperations.moveToTrash(fileItem.url)
                self?.refresh()
                self?.onFileSystemChange?()
            },
            onSetLabelColor: { [weak self] color in
                do {
                    try fileItem.setLabelColor(color)
                } catch {
                    NSLog("ClassicFinder: setLabelColor failed: \(error)")
                }
                self?.refresh()
                self?.onFileSystemChange?()
            }
        )
        items.forEach { menu.addItem($0) }
    }
}

extension ListViewController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil, let searchResults { return searchResults.count }
        if let fileItem = item as? FileItem, !fileItem.isBrowsable { return 0 }
        let url = (item as? FileItem)?.url ?? rootURL
        return children(of: url).count
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard searchResults == nil else { return false }
        return (item as? FileItem)?.isBrowsable ?? true
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil, let searchResults { return searchResults[index] }
        let url = (item as? FileItem)?.url ?? rootURL
        return children(of: url)[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileItem)?.url as NSURL?
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
        // Only allow dropping "onto" a browsable folder row, or into the
        // list's empty space (item == nil), which means "into rootURL".
        if let fileItem = item as? FileItem, !fileItem.isBrowsable { return [] }
        // validateDrop fires repeatedly as the mouse moves during the
        // drag, so this is where we reliably catch the Option/⌘ state —
        // see DragModifierTracker's doc comment for why.
        dragModifierTracker.sample()

        if let fileItem = item as? FileItem {
            springLoadTimer.hover(target: fileItem.url)
        } else {
            springLoadTimer.cancel()
        }

        return [.copy, .move]
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        springLoadTimer.cancel()
        let destinationDirectory = (item as? FileItem)?.url ?? rootURL
        guard let sourceURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return false }

        for sourceURL in sourceURLs {
            let operation = dragModifierTracker.resolve(source: sourceURL, destinationDirectory: destinationDirectory)
            _ = try? (operation == .copy
                ? FileOperations.copy(sourceURL, into: destinationDirectory)
                : FileOperations.move(sourceURL, into: destinationDirectory))
        }
        refresh()
        onFileSystemChange?()
        return true
    }
}

extension ListViewController: NSOutlineViewDelegate, NSTextFieldDelegate {
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem, let column = tableColumn else { return nil }
        let identifier = column.identifier

        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = makeCell(for: identifier)
        }
        configure(cell, for: fileItem, column: identifier)
        return cell
    }

    private func makeCell(for identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        if identifier.rawValue == "Name" {
            // Editable so classic Finder's "click an already-selected row's
            // name" rename gesture works via NSTableView's built-in
            // handling, in addition to the explicit Return-key path
            // (beginRename() -> editColumn).
            textField.isEditable = true
            textField.delegate = self

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            // Label-color indicator dot, found again in configure(_:) via
            // its tag since NSTableCellView only has first-class slots for
            // .textField/.imageView.
            let labelDot = NSImageView()
            labelDot.tag = Self.labelDotTag
            labelDot.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(labelDot)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                labelDot.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 4),
                labelDot.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                labelDot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                labelDot.widthAnchor.constraint(equalToConstant: 8),
                labelDot.heightAnchor.constraint(equalToConstant: 8),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    private func configure(_ cell: NSTableCellView, for fileItem: FileItem, column: NSUserInterfaceItemIdentifier) {
        switch column.rawValue {
        case "Name":
            cell.textField?.stringValue = fileItem.name
            cell.imageView?.image = IconCache.icon(for: fileItem.url)
            if let labelDot = cell.viewWithTag(Self.labelDotTag) as? NSImageView {
                let color = fileItem.labelColor
                labelDot.isHidden = color == .none
                labelDot.image = color == .none ? nil : LabelSwatchImage.make(for: color, diameter: 8)
            }
        case "DateModified":
            if let date = fileItem.modificationDate {
                cell.textField?.stringValue = DateFormatter.listView.string(from: date)
            } else {
                cell.textField?.stringValue = ""
            }
        case "Size":
            if fileItem.isBrowsable {
                cell.textField?.stringValue = "--"
            } else if let size = fileItem.fileSize {
                cell.textField?.stringValue = ByteCountFormatter.listView.string(fromByteCount: Int64(size))
            } else {
                cell.textField?.stringValue = ""
            }
        case "Kind":
            cell.textField?.stringValue = fileItem.kindDescription ?? ""
        default:
            break
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        let row = outlineView.row(for: textField)
        guard row >= 0, let fileItem = outlineView.item(atRow: row) as? FileItem else { return }
        let newName = textField.stringValue
        guard newName != fileItem.name else { return }
        _ = try? FileOperations.rename(fileItem.url, to: newName)
        refresh()
        onFileSystemChange?()
    }
}

private extension DateFormatter {
    static let listView: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension ByteCountFormatter {
    static let listView: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
