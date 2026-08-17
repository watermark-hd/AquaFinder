import AppKit
import FSCore
import FSUIKit

/// Classic Finder's Miller-column view, backed by NSBrowser — the same
/// control real Finder still uses for column view today. Uses the
/// object-based NSBrowserDelegate API (available since Snow Leopard itself,
/// 10.6) rather than the older path-string API.
public final class ColumnBrowserViewController: NSViewController {
    public var onSelectionChange: ((FileItem) -> Void)?
    /// Fired after this view performs a rename — lets MainWindowController
    /// refresh sibling views (List/Icon) and invalidate the shared
    /// directory cache, matching the same hook on List/Icon view.
    public var onFileSystemChange: (() -> Void)?
    /// Fired when "Get Info" is chosen from the right-click menu — opening
    /// the actual panel is MainWindowController's job, this view just
    /// reports the request (matches List/Icon).
    public var onShowInfo: ((FileItem) -> Void)?
    /// Fired when "Open in New Window" is chosen from the right-click menu
    /// on a folder (matches List/Icon).
    public var onOpenInNewWindow: ((FileItem) -> Void)?

    private let browser = ContextMenuBrowser()
    private var currentRoot: FileItem
    private var lastSelectedItem: FileItem?

    /// When non-nil, column zero shows this flat list instead of
    /// `currentRoot`'s contents, and every row is forced to a leaf — a
    /// single flat column of results, the same shape real Finder shows
    /// while searching in Column view — rather than the search matches
    /// being independently browsable subtrees of themselves.
    private var searchResults: [FileItem]?
    private var sortField: FileSortField = .name

    // NSBrowser queries numberOfChildrenOfItem/child(_:ofItem:) repeatedly
    // per column; DirectoryListingCache (shared with List/Icon view and the
    // status bar) avoids re-hitting the disk and re-sorting the same
    // folder's contents multiple times per navigation.
    private func children(of url: URL) -> [FileItem] {
        FileSorting.sorted(DirectoryListingCache.contents(of: url), by: sortField)
    }

    /// Set from the View menu's "Arrange By" — Column view has no column
    /// headers to click the way List view does.
    public func applySortField(_ field: FileSortField) {
        sortField = field
        guard browser.lastColumn >= 0 else { return }
        for column in 0...browser.lastColumn {
            browser.reloadColumn(column)
        }
    }

    public init(rootURL: URL) {
        currentRoot = FileItem(url: rootURL)
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

        browser.delegate = self
        browser.isTitled = false
        // Defaults to false — without this, Shift/Cmd-click only ever
        // ends up with the single last-clicked row selected.
        browser.allowsMultipleSelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        // Default (.autoColumnResizing) fights the user for column width;
        // classic Finder lets you drag each column's edge to resize it.
        browser.columnResizingType = .userColumnResizing
        // .userColumnResizing has no sane width of its own to fall back
        // on — without these, new columns default to a cramped width
        // that crowds too many columns into the window at once.
        browser.minColumnWidth = 150
        browser.setDefaultColumnWidth(190)
        browser.setCellClass(FileBrowserCell.self)
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.doubleAction = #selector(handleDoubleClick)
        browser.menuProvider = { [weak self] row, column in
            self?.contextMenu(atRow: row, column: column)
        }

        view.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: view.topAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        browser.loadColumnZero()
    }

    /// Called on every navigation — including a double-click descent deep
    /// into a folder from Icon/List view, which by itself never touches
    /// Column view at all. Rooting at `url` directly would show only its
    /// own contents with no ancestor columns, hiding exactly the "folder
    /// above" context real Finder still shows after switching view modes
    /// mid-navigation. Rooting at the home directory instead and
    /// selecting down to `url` reconstructs that ancestor chain, as long
    /// as `url` actually lives under home — Applications, a mounted
    /// volume, or a network share have no meaningful ancestor chain to
    /// reconstruct anyway, so those just root at `url` directly as before.
    public func setRoot(_ url: URL) {
        currentRoot = Self.ancestorRoot(for: url)
        lastSelectedItem = nil
        browser.loadColumnZero()
        if currentRoot.url != url {
            selectItem(at: url)
        }
    }

    private static func ancestorRoot(for url: URL) -> FileItem {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count > home.count, Array(target.prefix(home.count)) == home else {
            return FileItem(url: url)
        }
        return FileItem(url: FileManager.default.homeDirectoryForCurrentUser)
    }

    public func showSearchResults(_ items: [FileItem]) {
        searchResults = items
        lastSelectedItem = nil
        browser.loadColumnZero()
    }

    public func clearSearchResults() {
        searchResults = nil
        lastSelectedItem = nil
        browser.loadColumnZero()
    }

    @objc private func selectionChanged() {
        let column = browser.selectedColumn
        guard column >= 0 else { return }
        let row = browser.selectedRow(inColumn: column)
        guard row >= 0, let item = browser.item(atRow: row, inColumn: column) as? FileItem else { return }
        lastSelectedItem = item
        onSelectionChange?(item)
    }

    @objc private func handleDoubleClick() {
        guard let item = lastSelectedItem, !item.isBrowsable else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Right-clicking a row selects it first (matching List/Icon), then
    /// builds the shared context menu for it.
    private func contextMenu(atRow row: Int, column: Int) -> NSMenu? {
        guard let fileItem = browser.item(atRow: row, inColumn: column) as? FileItem else { return nil }
        browser.selectRow(row, inColumn: column)
        lastSelectedItem = fileItem
        onSelectionChange?(fileItem)

        let menu = NSMenu()
        let items = FileContextMenu.items(
            for: fileItem,
            onGetInfo: { [weak self] in self?.onShowInfo?(fileItem) },
            onRename: { [weak self] in self?.beginRename() },
            onDuplicate: { [weak self] in
                _ = try? FileOperations.duplicate(fileItem.url)
                self?.reloadAfterChange(toParentOf: fileItem, inColumn: column)
            },
            onCompress: { [weak self] in
                _ = try? FileOperations.compress(fileItem.url)
                self?.reloadAfterChange(toParentOf: fileItem, inColumn: column)
            },
            onMoveToTrash: { [weak self] in
                _ = try? FileOperations.moveToTrash(fileItem.url)
                self?.reloadAfterChange(toParentOf: fileItem, inColumn: column)
            },
            onSetLabelColor: { [weak self] color in
                do {
                    try fileItem.setLabelColor(color)
                } catch {
                    NSLog("AquaFinder: setLabelColor failed: \(error)")
                }
                self?.reloadAfterChange(toParentOf: fileItem, inColumn: column)
            },
            onOpenInNewWindow: { [weak self] in self?.onOpenInNewWindow?(fileItem) }
        )
        items.forEach { menu.addItem($0) }
        return menu
    }

    /// Reloads the column that actually contains the item a context-menu
    /// action just changed — `refresh()`'s `browser.lastColumn` targets a
    /// different column whenever the changed item itself is a folder (its
    /// own row sits one column to the left of the empty preview column
    /// `lastColumn` points at).
    private func reloadAfterChange(toParentOf fileItem: FileItem, inColumn column: Int) {
        DirectoryListingCache.invalidate(fileItem.url.deletingLastPathComponent())
        browser.reloadColumn(column)
        onFileSystemChange?()
    }
}

/// NSBrowser has no NSMenuDelegate-driven "which cell was clicked" hook the
/// way NSTableView does; overriding `menu(for:)` directly gives us the
/// click location to hit-test against, matching the pattern used for
/// Icon view's ContextMenuCollectionView.
final class ContextMenuBrowser: NSBrowser {
    var menuProvider: ((_ row: Int, _ column: Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        var row = 0
        var column = 0
        guard getRow(&row, column: &column, for: point) else { return nil }
        return menuProvider?(row, column)
    }
}

/// Registered via `browser.setCellClass(_:)` so every cell the browser
/// creates is one of these. Intercepting `objectValue` here — rather than
/// `willDisplayCell(atRow:column:)`, NSBrowser's usual per-cell
/// customization point — is what actually works for an item-based
/// browser; see the doc comment on `objectValueForItem` above for why.
final class FileBrowserCell: NSBrowserCell {
    override var objectValue: Any? {
        get { super.objectValue }
        set {
            guard let fileItem = newValue as? FileItem else {
                super.objectValue = newValue
                return
            }
            image = IconCache.icon(for: fileItem.url)
            // NSCell's `image` setter switches the cell's `type` to
            // `.imageCellType` as a side effect (documented Apple
            // behavior). Left alone, that broke the rename field editor —
            // it seeds its initial text from a text-type cell, so once
            // this cell silently became an image cell, editing opened
            // with an empty box instead of the current name. Forcing it
            // back to `.textCellType` restores that while the icon still
            // draws fine, since NSBrowserCell always draws image + title
            // together regardless of `type`.
            type = .textCellType
            // Needed for rename (editItem(at:with:select:)) to actually
            // start an edit session — NSCell defaults to false, and
            // nothing else in this class's setup ever touches it.
            isEditable = true
            super.objectValue = fileItem.name
        }
    }

    /// The one place every editing session on this cell is guaranteed to
    /// pass through, no matter what starts it — a Return keypress is
    /// handled inside NSBrowser's private per-column NSMatrix and never
    /// reaches any of NSBrowser's own public methods or AppKit's usual
    /// text-editing notifications (confirmed by instrumentation: none of
    /// them fired). `stringValue` here is already the plain file name —
    /// set by the `objectValue` setter above whenever this cell was last
    /// configured for display — so this doesn't need any outside context
    /// to reseed the editor and fix its color.
    override func edit(
        withFrame aRect: NSRect, in controlView: NSView, editor textObj: NSText, delegate anObject: Any?, event theEvent: NSEvent?
    ) {
        super.edit(withFrame: aRect, in: controlView, editor: textObj, delegate: anObject, event: theEvent)
        textObj.string = stringValue
        textObj.textColor = .controlTextColor
        textObj.selectAll(nil)
    }
}

extension ColumnBrowserViewController: SelectionProviding {
    /// All selected rows in whichever column currently has the selection
    /// — not just `lastSelectedItem`, which only ever tracks one (the
    /// "primary" one selectionChanged() last saw), so this stayed
    /// single-item even once allowsMultipleSelection made the browser
    /// itself highlight a multi-row selection.
    public var selectedURLs: [URL] {
        browser.selectionIndexPaths.compactMap { browser.item(at: $0) as? FileItem }.map(\.url)
    }

    /// The deepest selected folder (or the parent of a selected leaf file);
    /// falls back to the root itself when nothing is selected yet. Column
    /// view has no cheap way to map an arbitrary column index back to a
    /// filesystem path, so this relies on the last selection-changed event
    /// rather than reconstructing it from `browser`'s column state.
    public var currentDirectoryURL: URL {
        guard let selected = lastSelectedItem else { return currentRoot.url }
        return selected.isBrowsable ? selected.url : selected.url.deletingLastPathComponent()
    }

    public func refresh() {
        let column = browser.lastColumn
        guard column >= 0 else { return }
        browser.reloadColumn(column)
    }

    public func beginRename() {
        guard let indexPath = browser.selectionIndexPath else { return }
        browser.editItem(at: indexPath, with: nil, select: true)
    }

    /// Selects (and scrolls to) `url`, expanding whichever columns are
    /// needed to reach it — built by matching path components against each
    /// column's live listing, since NSBrowser's item-based API has no
    /// direct "URL to index path" lookup.
    public func selectItem(at url: URL) {
        guard let indexPath = indexPath(forItemAt: url) else { return }
        browser.selectionIndexPath = indexPath
        browser.scrollColumnToVisible(indexPath.count - 1)
        lastSelectedItem = FileItem(url: url)
    }

    private func indexPath(forItemAt url: URL) -> IndexPath? {
        let rootComponents = currentRoot.url.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }

        var indexes: [Int] = []
        var siblings = children(of: currentRoot.url)
        for component in targetComponents[rootComponents.count...] {
            guard let index = siblings.firstIndex(where: { $0.url.lastPathComponent == component }) else { return nil }
            indexes.append(index)
            siblings = children(of: siblings[index].url)
        }
        return IndexPath(indexes: indexes)
    }
}

extension ColumnBrowserViewController: NSBrowserDelegate {
    public func rootItem(for browser: NSBrowser) -> Any? {
        currentRoot
    }

    public func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let fileItem = item as? FileItem else { return 0 }
        if let searchResults, fileItem.url == currentRoot.url { return searchResults.count }
        guard fileItem.isBrowsable else { return 0 }
        return children(of: fileItem.url).count
    }

    public func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        guard let fileItem = item as? FileItem else {
            preconditionFailure("unexpected browser item")
        }
        if let searchResults, fileItem.url == currentRoot.url {
            return FileSorting.sorted(searchResults, by: sortField)[index]
        }
        return children(of: fileItem.url)[index]
    }

    public func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let fileItem = item as? FileItem else { return true }
        // While showing search results, every row is forced to a leaf —
        // see the doc comment on `searchResults` for why.
        if searchResults != nil { return true }
        return !fileItem.isBrowsable
    }

    // Returning the FileItem itself (not just its name) is what lets
    // FileBrowserCell's objectValue override below pull the icon out —
    // willDisplayCell(atRow:column:), the usual place to set a browser
    // cell's image, turns out to belong to NSBrowser's older matrix-based
    // delegate API and is simply never called once a browser is
    // configured with the item-based methods this class uses instead.
    public func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        item as? FileItem
    }

    public func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool {
        true
    }

    public func browser(_ browser: NSBrowser, setObjectValue object: Any?, forItem item: Any?) {
        guard let fileItem = item as? FileItem,
              let newName = object as? String,
              newName != fileItem.name,
              let destination = try? FileOperations.rename(fileItem.url, to: newName)
        else { return }
        DirectoryListingCache.invalidate(fileItem.url.deletingLastPathComponent())
        lastSelectedItem = FileItem(url: destination)
        browser.reloadColumn(browser.selectedColumn)
        onFileSystemChange?()
    }
}
