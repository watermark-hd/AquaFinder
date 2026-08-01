import AppKit
import FSCore
import FSUIKit

/// Classic Finder's Miller-column view, backed by NSBrowser — the same
/// control real Finder still uses for column view today. Uses the
/// object-based NSBrowserDelegate API (available since Snow Leopard itself,
/// 10.6) rather than the older path-string API.
public final class ColumnBrowserViewController: NSViewController {
    public var onSelectionChange: ((FileItem) -> Void)?

    private let browser = NSBrowser()
    private var currentRoot: FileItem
    private var lastSelectedItem: FileItem?

    // NSBrowser queries numberOfChildrenOfItem/child(_:ofItem:) repeatedly
    // per column; without this cache each of those re-hit the disk and
    // re-sorted the folder's contents.
    private var childrenCache: [URL: [FileItem]] = [:]

    private func children(of url: URL) -> [FileItem] {
        if let cached = childrenCache[url] { return cached }
        let result = FileListing.contents(of: url)
        childrenCache[url] = result
        return result
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
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.doubleAction = #selector(handleDoubleClick)

        view.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: view.topAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        browser.loadColumnZero()
    }

    /// Resets the browser to a new root, collapsing all columns — used
    /// when the sidebar selection or back/forward navigation changes which
    /// top-level location is being browsed.
    public func setRoot(_ url: URL) {
        currentRoot = FileItem(url: url)
        lastSelectedItem = nil
        childrenCache.removeAll()
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
}

extension ColumnBrowserViewController: SelectionProviding {
    public var selectedURLs: [URL] {
        lastSelectedItem.map { [$0.url] } ?? []
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
        childrenCache.removeValue(forKey: currentDirectoryURL)
        let column = browser.lastColumn
        guard column >= 0 else { return }
        browser.reloadColumn(column)
    }

    public func beginRename() {
        // NSBrowser doesn't offer cell editing the way NSTableView/
        // NSCollectionView do; column-view rename is deferred (noted in
        // the project plan as a known Phase 2 scope trim).
    }

    public func selectItem(at url: URL) {
        // Mapping an arbitrary URL back to a specific column/row isn't
        // cheap with NSBrowser's object-based API (same limitation noted
        // on currentDirectoryURL above); Quick Look's arrow-key selection
        // sync is scoped to List/Icon view for now.
    }
}

extension ColumnBrowserViewController: NSBrowserDelegate {
    public func rootItem(for browser: NSBrowser) -> Any? {
        currentRoot
    }

    public func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let fileItem = item as? FileItem, fileItem.isBrowsable else { return 0 }
        return children(of: fileItem.url).count
    }

    public func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        guard let fileItem = item as? FileItem else {
            preconditionFailure("unexpected browser item")
        }
        return children(of: fileItem.url)[index]
    }

    public func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let fileItem = item as? FileItem else { return true }
        return !fileItem.isBrowsable
    }

    public func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? FileItem)?.name
    }

    public func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let browserCell = cell as? NSBrowserCell,
              let fileItem = browser.item(atRow: row, inColumn: column) as? FileItem else { return }
        browserCell.image = IconCache.icon(for: fileItem.url)
        browserCell.isLeaf = !fileItem.isBrowsable
    }
}
