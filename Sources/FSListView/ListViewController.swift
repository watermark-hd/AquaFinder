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
    /// Fired when "Open in New Window" is chosen from the right-click menu
    /// on a folder — MainWindowController delegates the actual window
    /// creation to AppDelegate.
    public var onOpenInNewWindow: ((FileItem) -> Void)?
    /// Fired on any selection change — MainWindowController uses this to
    /// keep an open Quick Look panel in sync without caring which view
    /// mode is actually active.
    public var onSelectionChange: (() -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var rootURL: URL
    fileprivate static let labelDotTag = 998

    /// When non-nil, the outline shows this flat list instead of
    /// `rootURL`'s contents — how search results get displayed (Icon and
    /// Column view have their own equivalent; see MainWindowController).
    private var searchResults: [FileItem]?

    private let dragModifierTracker = DragModifierTracker()
    private let springLoadTimer = SpringLoadTimer()

    // フォルダの再帰サイズは非同期・キャンセル可能（Get Info と同じ
    // FolderSizeCalculator）。NSOutlineView はオフスクリーン行のセルを
    // 作らないため、同時に走る計算は自然と「今画面に見えている行」程度に
    // 絞られる。
    private var folderSizeCache: [URL: Int64] = [:]
    private var pendingSizeCalculators: [URL: FolderSizeCalculator] = [:]
    private var textSize: TextSize = AppearancePreferenceStore.textSize

    private enum SortKey: String {
        case name = "Name"
        case dateModified = "DateModified"
        case size = "Size"
        case kind = "Kind"
    }

    private var sortKey: SortKey = .name
    private var sortAscending = true

    public init(rootURL: URL) {
        self.rootURL = rootURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingSizeCalculators.values.forEach { $0.cancel() }
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
        resetFolderSizes()
        outlineView.reloadData()
    }

    public func applyTextSize(_ textSize: TextSize) {
        self.textSize = textSize
        outlineView.rowHeight = textSize.listRowHeight
        outlineView.reloadData()
    }

    private func resetFolderSizes() {
        pendingSizeCalculators.values.forEach { $0.cancel() }
        pendingSizeCalculators.removeAll()
        folderSizeCache.removeAll()
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
        nameColumn.title = NSLocalizedString("Name", comment: "リスト表示の列見出し: 名前")
        nameColumn.width = 260
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DateModified"))
        dateColumn.title = NSLocalizedString("Date Modified", comment: "リスト表示の列見出し: 変更日")
        dateColumn.width = 150
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.dateModified.rawValue, ascending: true)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = NSLocalizedString("Size", comment: "リスト表示の列見出し: サイズ")
        sizeColumn.width = 80
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.size.rawValue, ascending: true)

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Kind"))
        kindColumn.title = NSLocalizedString("Kind", comment: "リスト表示の列見出し: 種類")
        kindColumn.width = 120
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.kind.rawValue, ascending: true)

        [nameColumn, dateColumn, sizeColumn, kindColumn].forEach { outlineView.addTableColumn($0) }
        outlineView.outlineTableColumn = nameColumn
        outlineView.dataSource = self
        outlineView.delegate = self
        // Name-ascending by default, matching real Finder and the order
        // FileListing/DirectoryListingCache already hand back — clicking
        // a header toggles/re-targets from here via sortDescriptorsDidChange.
        outlineView.sortDescriptors = [nameColumn.sortDescriptorPrototype!]
        outlineView.usesAlternatingRowBackgroundColors = true
        // Defaults to false — without this, Shift/Cmd-click and drag-to-
        // select-rectangle only ever end up with the single last-clicked
        // row selected, no matter how the user selects.
        outlineView.allowsMultipleSelection = true
        outlineView.rowHeight = textSize.listRowHeight
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

        outlineView.backgroundColor = .clear
        // NSScrollView's own background drawing uses a dynamic system color
        // that doesn't respect the forced Aqua appearance and can paint
        // black in Dark Mode (visible below the last row); rely on the
        // window's own always-light content background instead. See the
        // matching comment in IconViewController.
        scrollView.drawsBackground = false
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
        sorted(DirectoryListingCache.contents(of: url))
    }

    private func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            let comparison = compare(lhs, rhs)
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func compare(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        switch sortKey {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .dateModified:
            return compare(lhs.modificationDate ?? .distantPast, rhs.modificationDate ?? .distantPast)
        case .size:
            return compare(sizeForSorting(lhs), sizeForSorting(rhs))
        case .kind:
            return (lhs.kindDescription ?? "").localizedStandardCompare(rhs.kindDescription ?? "")
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// Folder sizes are only known once FolderSizeCalculator finishes (see
    /// startFolderSizeCalculationIfNeeded below) — folders not yet
    /// calculated sort as 0 rather than blocking on a synchronous walk.
    private func sizeForSorting(_ item: FileItem) -> Int64 {
        if item.isBrowsable {
            return folderSizeCache[item.url] ?? 0
        }
        return Int64(item.fileSize ?? 0)
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
        resetFolderSizes()
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
            onCompress: { [weak self] in
                _ = try? FileOperations.compress(fileItem.url)
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
                    NSLog("AquaFinder: setLabelColor failed: \(error)")
                }
                self?.refresh()
                self?.onFileSystemChange?()
            },
            onOpenInNewWindow: { [weak self] in self?.onOpenInNewWindow?(fileItem) }
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
        if item == nil, let searchResults { return sorted(searchResults)[index] }
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

    public func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key, let newSortKey = SortKey(rawValue: key)
        else { return }
        sortKey = newSortKey
        sortAscending = descriptor.ascending
        outlineView.reloadData()
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
        if identifier.rawValue == "Name" {
            let cell = ListNameCell()
            cell.identifier = identifier
            cell.textField?.isEditable = true
            cell.textField?.delegate = self
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configure(_ cell: NSTableCellView, for fileItem: FileItem, column: NSUserInterfaceItemIdentifier) {
        cell.textField?.font = NSFont.systemFont(ofSize: textSize.baseFontSize)
        if let nameCell = cell as? ListNameCell {
            nameCell.imageSizeConstraints.forEach { $0.constant = textSize.rowIconSize }
        }
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
                if let cachedSize = folderSizeCache[fileItem.url] {
                    cell.textField?.stringValue = ByteCountFormatter.listView.string(fromByteCount: cachedSize)
                } else {
                    cell.textField?.stringValue = "--"
                    startFolderSizeCalculationIfNeeded(for: fileItem)
                }
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

    private func startFolderSizeCalculationIfNeeded(for fileItem: FileItem) {
        guard pendingSizeCalculators[fileItem.url] == nil else { return }
        let calculator = FolderSizeCalculator()
        pendingSizeCalculators[fileItem.url] = calculator
        calculator.calculate(fileItem.url) { [weak self] bytes in
            guard let self else { return }
            self.pendingSizeCalculators.removeValue(forKey: fileItem.url)
            self.folderSizeCache[fileItem.url] = bytes
            self.outlineView.reloadItem(fileItem)
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

/// Name 列専用のセル。ファイルアイコンの表示サイズを文字サイズ設定に応じて
/// 変えられるよう、幅・高さの制約を使い回せる形で保持しておく。
private final class ListNameCell: NSTableCellView {
    let imageSizeConstraints: [NSLayoutConstraint]

    override init(frame frameRect: NSRect) {
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail

        // Editable so classic Finder's "click an already-selected row's
        // name" rename gesture works via NSTableView's built-in handling,
        // in addition to the explicit Return-key path (beginRename() ->
        // editColumn).
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // Label-color indicator dot, found again in configure(_:) via its
        // tag since NSTableCellView only has first-class slots for
        // .textField/.imageView.
        let labelDot = NSImageView()
        labelDot.tag = ListViewController.labelDotTag
        labelDot.translatesAutoresizingMaskIntoConstraints = false

        let widthConstraint = imageView.widthAnchor.constraint(equalToConstant: 16)
        let heightConstraint = imageView.heightAnchor.constraint(equalToConstant: 16)
        imageSizeConstraints = [widthConstraint, heightConstraint]

        super.init(frame: frameRect)

        addSubview(imageView)
        addSubview(textField)
        addSubview(labelDot)
        self.imageView = imageView
        self.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint,
            heightConstraint,
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelDot.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 4),
            labelDot.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            labelDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelDot.widthAnchor.constraint(equalToConstant: 8),
            labelDot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
