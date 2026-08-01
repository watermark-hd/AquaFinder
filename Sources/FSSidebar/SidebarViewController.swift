import AppKit
import FSCore
import FSUIKit

/// Snow Leopard-era sidebar: two fixed groups, DEVICES (mounted volumes)
/// and PLACES (Home/Desktop/Documents/Applications) — predates the Big Sur
/// "Favorites" reshuffle, and there's no Shared/network section yet since
/// Connect-to-Server is deferred. Uses stock `.sourceList` selection
/// styling for now; the fully custom Snow-Leopard gradient/appearance pass
/// is deferred to the Phase 5 polish pass.
public final class SidebarViewController: NSViewController {
    public var onSelect: ((FileItem) -> Void)?
    /// Fired after a file gets dropped onto a sidebar row — the sidebar
    /// has no reference to whichever content view is currently displaying
    /// the drag's *source* folder, so it can't refresh that pane itself;
    /// MainWindowController refreshes everything in response instead.
    public var onFileSystemChange: (() -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let dragModifierTracker = DragModifierTracker()
    private let springLoadTimer = SpringLoadTimer()
    private var sections: [SidebarSection] = []

    public override func loadView() {
        view = NSView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        sections = [
            SidebarSection(title: "DEVICES", items: VolumeInfo.mountedVolumes()),
            SidebarSection(title: "PLACES", items: WellKnownLocations.places()),
        ]
        setUpOutlineView()
        outlineView.reloadData()
        sections.forEach { outlineView.expandItem($0) }
        selectDefaultLocation()
        // Spring-loading onto a sidebar row navigates there, same as a
        // click — hovering a drag over "Documents" for ~0.75s takes you
        // to Documents, matching real Finder's sidebar spring-loading.
        springLoadTimer.onActivate = { [weak self] url in
            self?.onSelect?(FileItem(url: url))
        }
    }

    /// Selects Home under PLACES, which also drives the initial navigation
    /// state via the same `onSelect` path real clicks go through.
    public func selectDefaultLocation() {
        guard let places = sections.first(where: { $0.title == "PLACES" }),
              let home = places.items.first else { return }
        let row = outlineView.row(forItem: home)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func setUpOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.rowHeight = 20
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

/// Reference type so NSOutlineView's item-identity tracking (expandItem,
/// row(forItem:)) has something stable to key off; FileItem is a value type
/// and only appears as a leaf child, never needs that stability itself.
private final class SidebarSection {
    let title: String
    let items: [FileItem]

    init(title: String, items: [FileItem]) {
        self.title = title
        self.items = items
    }
}

extension SidebarViewController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        if let section = item as? SidebarSection { return section.items.count }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        if let section = item as? SidebarSection { return section.items[index] }
        preconditionFailure("unexpected sidebar item")
    }

    // Sidebar rows are drop targets only (you can copy/move files onto a
    // Places/Devices shortcut), not drag sources — dragging a sidebar
    // shortcut out doesn't copy the folder itself in real Finder either.
    public func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let fileItem = item as? FileItem, fileItem.isBrowsable,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        else { return [] }
        // validateDrop fires repeatedly as the mouse moves during the
        // drag, so this is where we reliably catch the Option/⌘ state —
        // see DragModifierTracker's doc comment for why.
        dragModifierTracker.sample()
        springLoadTimer.hover(target: fileItem.url)
        return [.copy, .move]
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        springLoadTimer.cancel()
        guard let destinationItem = item as? FileItem, destinationItem.isBrowsable,
              let sourceURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return false }

        for sourceURL in sourceURLs {
            let operation = dragModifierTracker.resolve(source: sourceURL, destinationDirectory: destinationItem.url)
            _ = try? (operation == .copy
                ? FileOperations.copy(sourceURL, into: destinationItem.url)
                : FileOperations.move(sourceURL, into: destinationItem.url))
        }
        onFileSystemChange?()
        return true
    }
}

extension SidebarViewController: NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is SidebarSection)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            return groupCell(title: section.title)
        }
        if let fileItem = item as? FileItem {
            return itemCell(for: fileItem)
        }
        return nil
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let fileItem = outlineView.item(atRow: row) as? FileItem else { return }
        onSelect?(fileItem)
    }

    private func groupCell(title: String) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("GroupCell")
        let textField: NSTextField
        if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            textField.textColor = .secondaryLabelColor
        }
        textField.stringValue = title
        return textField
    }

    private func itemCell(for fileItem: FileItem) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("ItemCell")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = fileItem.name
        cell.imageView?.image = IconCache.icon(for: fileItem.url)
        return cell
    }
}
