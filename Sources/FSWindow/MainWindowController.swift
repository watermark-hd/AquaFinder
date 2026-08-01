import AppKit
import Quartz
import FSCore
import FSUIKit
import FSSidebar
import FSColumnView
import FSListView
import FSIconView
import FSGetInfo

public final class MainWindowController: NSWindowController {
    private let sidebarVC = SidebarViewController()
    private let columnVC: ColumnBrowserViewController
    private let listVC: ListViewController
    private let iconVC: IconViewController
    private let contentContainer = ContentContainerViewController()
    private let statusBarView = StatusBarView(frame: .zero)

    private var historyStack: [URL] = []
    private var historyIndex = -1
    private var currentViewMode: ViewMode = ViewModePreferenceStore.loadViewMode()
    private var currentRootURL: URL

    // Keyed by file so re-choosing "Get Info" on the same item just
    // refocuses its existing panel instead of spawning duplicates;
    // real Finder does the same.
    private var getInfoWindows: [URL: GetInfoWindowController] = [:]

    // Quick Look's spacebar shortcut isn't a standard NSMenuItem key
    // equivalent (plain space, no modifier), so it's caught with a local
    // event monitor scoped to this app's own windows instead. The same
    // monitor also drives Up/Down arrow-key navigation while the panel is
    // open — QLPreviewPanel only binds Left/Right itself, so Up/Down
    // otherwise silently does nothing while the panel is key.
    private var spacebarMonitor: Any?
    // Keeps the browser's selection highlight following along as the
    // user steps through Quick Look — both our own Up/Down handling and
    // QLPreviewPanel's native Left/Right change this property, so
    // observing it (rather than hooking each navigation path separately)
    // covers both.
    private var quickLookIndexObservation: NSKeyValueObservation?

    // Search is scoped to List View only (see the doc comment on
    // ListViewController.showSearchResults) — starting a search force-
    // switches to List View and this remembers what to switch back to
    // once the search field is cleared.
    private let searchField = NSSearchField()
    private var searchQuery: NSMetadataQuery?
    private var viewModeBeforeSearch: ViewMode?

    private lazy var navigationControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["\u{25C0}", "\u{25B6}"],
            trackingMode: .momentary,
            target: self,
            action: #selector(navigationControlClicked(_:))
        )
        control.segmentStyle = .separated
        control.setEnabled(false, forSegment: 0)
        control.setEnabled(false, forSegment: 1)
        return control
    }()

    private lazy var viewModeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["Icon", "List", "Column"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(viewModeChanged(_:))
        )
        control.setSelected(true, forSegment: currentViewMode.rawValue)
        return control
    }()

    public convenience init() {
        self.init(rootURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    public init(rootURL: URL) {
        columnVC = ColumnBrowserViewController(rootURL: rootURL)
        listVC = ListViewController(rootURL: rootURL)
        iconVC = IconViewController(rootURL: rootURL)
        currentRootURL = rootURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClassicFinder"
        // Snow Leopard's window chrome was a continuous light-gray
        // gradient across titlebar + toolbar, not the modern flat-white
        // unified bar. Making the titlebar transparent lets the window's
        // own backgroundColor show through it; toolbarStyle .unified (11+)
        // keeps the toolbar strip in that same continuous surface instead
        // of drawing its own separate vibrancy material underneath.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("MainWindow")
        // setFrameAutosaveName restores a previously-saved frame if one
        // exists; guard against restoring a degenerate tiny frame (e.g.
        // saved during development while the window was being scripted
        // around) by resetting to the intended default size whenever the
        // restored frame falls below a sane floor.
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 900, height: 560))
        }
        window.center()

        super.init(window: window)

        historyStack = [rootURL]
        historyIndex = 0

        setUpContent()
        setUpToolbar()
        showActiveViewController()
        updateStatusBar()

        columnVC.onSelectionChange = { [weak self] _ in
            // File selection within a column doesn't change navigation
            // history by itself; that's reserved for drilling into a new
            // root via the sidebar or double-click in Icon/List view.
            self?.quickLookSelectionDidChange()
        }
        listVC.onOpen = { [weak self] url in
            self?.navigate(to: url, pushHistory: true)
        }
        iconVC.onOpen = { [weak self] url in
            self?.navigate(to: url, pushHistory: true)
        }
        sidebarVC.onSelect = { [weak self] fileItem in
            self?.navigate(to: fileItem.url, pushHistory: true)
        }

        // A rename or drag copy/move performed inside List/Icon/Sidebar
        // only refreshes that view's own on-screen pane by itself — a
        // sidebar drop's source pane, or the two view modes not currently
        // visible, have no way to know their cached listing is stale
        // otherwise. Refresh everything uniformly instead of trying to
        // track exactly which pane(s) actually changed.
        listVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }
        iconVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }
        sidebarVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }

        listVC.onShowInfo = { [weak self] fileItem in self?.showGetInfo(for: fileItem) }
        iconVC.onShowInfo = { [weak self] fileItem in self?.showGetInfo(for: fileItem) }

        listVC.onSelectionChange = { [weak self] in self?.quickLookSelectionDidChange() }
        iconVC.onSelectionChange = { [weak self] in self?.quickLookSelectionDidChange() }

        setUpSpacebarMonitor()
        setUpSearchField()
    }

    deinit {
        if let spacebarMonitor {
            NSEvent.removeMonitor(spacebarMonitor)
        }
        quickLookIndexObservation?.invalidate()
        searchQuery?.stop()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpContent() {
        let splitVC = NSSplitViewController()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 260
        splitVC.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentContainer)
        splitVC.addSplitViewItem(contentItem)

        // Wrapped in a plain root view controller so the split view (sidebar
        // + browsing pane) can sit above a fixed-height status bar, while
        // still being a proper child view controller of something (the
        // window's contentViewController itself has to be that root, not
        // splitVC directly, for the child-VC hierarchy to be well-formed).
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.translatesAutoresizingMaskIntoConstraints = false

        // window.backgroundColor is gray so it shows through the
        // transparent titlebar/toolbar strip above this view — but that
        // same gray would otherwise show through *this* view too (and any
        // gaps within it) unless it paints its own opaque background, so
        // the gray doesn't end up washing out the whole window.
        let rootView = NSView()
        rootView.wantsLayer = true
        // .windowBackgroundColor reads as a light gray (it's meant for
        // chrome, not content) — classic Finder's file-listing area is
        // near-white, so use the semantically "content area" color.
        rootView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        rootView.addSubview(splitVC.view)
        rootView.addSubview(statusBarView)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: rootView.topAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            statusBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 22),
        ])

        let rootVC = NSViewController()
        rootVC.view = rootView
        rootVC.addChild(splitVC)

        contentViewController = rootVC
    }

    private func showActiveViewController() {
        switch currentViewMode {
        case .icon:
            contentContainer.setContent(iconVC)
        case .list:
            contentContainer.setContent(listVC)
        case .column:
            contentContainer.setContent(columnVC)
        }
    }

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .unified
        }
    }

    private func navigate(to url: URL, pushHistory: Bool) {
        if pushHistory {
            let isSameAsCurrent = historyIndex >= 0 && historyStack[historyIndex] == url
            if !isSameAsCurrent {
                if historyIndex + 1 < historyStack.count {
                    historyStack.removeSubrange((historyIndex + 1)...)
                }
                historyStack.append(url)
                historyIndex += 1
            }
        }
        currentRootURL = url
        columnVC.setRoot(url)
        listVC.setRoot(url)
        iconVC.setRoot(url)
        updateNavigationButtonsState()
        updateStatusBar()
    }

    @objc private func navigationControlClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: goBack()
        case 1: goForward()
        default: break
        }
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigate(to: historyStack[historyIndex], pushHistory: false)
    }

    private func goForward() {
        guard historyIndex < historyStack.count - 1 else { return }
        historyIndex += 1
        navigate(to: historyStack[historyIndex], pushHistory: false)
    }

    private func updateNavigationButtonsState() {
        navigationControl.setEnabled(historyIndex > 0, forSegment: 0)
        navigationControl.setEnabled(historyIndex < historyStack.count - 1, forSegment: 1)
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        guard let mode = ViewMode(rawValue: sender.selectedSegment) else { return }
        currentViewMode = mode
        ViewModePreferenceStore.saveViewMode(mode)
        showActiveViewController()
    }

    private var activeBrowser: SelectionProviding {
        switch currentViewMode {
        case .icon: return iconVC
        case .list: return listVC
        case .column: return columnVC
        }
    }

    private func refreshAllViews() {
        columnVC.refresh()
        listVC.refresh()
        iconVC.refresh()
        updateStatusBar()
    }

    private func updateStatusBar() {
        let count = FileListing.contents(of: currentRootURL).count
        statusBarView.update(itemCount: count, directoryURL: currentRootURL)
    }

    // MARK: - Quick Look

    private func setUpSpacebarMonitor() {
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Arrow keys (and other function-row-ish keys) always carry
            // .numericPad/.function in modifierFlags regardless of what
            // the user is actually holding down — checking against the
            // full .deviceIndependentFlagsMask treated every arrow-key
            // press as "modified" and skipped this handler entirely.
            // Only real modifier keys should disqualify a match.
            let realModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard event.modifierFlags.intersection(realModifiers).isEmpty else { return event }

            if event.keyCode == 49 { // space
                // Don't hijack space while editing a text field (rename,
                // search field, Get Info's label, etc.) — it should just
                // type a space there instead of toggling Quick Look.
                if let responder = self.window?.firstResponder, responder is NSText {
                    return event
                }
                self.toggleQuickLook()
                return nil
            }

            if event.keyCode == 125 || event.keyCode == 126, // down / up
               let panel = QLPreviewPanel.shared(), panel.isVisible {
                // In a real icon grid, Down/Up move by a full row, not by
                // one item the way Left/Right (and List View's Down/Up,
                // since it's already single-column) do.
                let step = self.currentViewMode == .icon ? self.iconVC.itemsPerRow : 1
                self.stepQuickLook(by: event.keyCode == 125 ? step : -step)
                return nil
            }

            return event
        }
    }

    @objc public func toggleQuickLook(_ sender: Any? = nil) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            quickLookIndexObservation?.invalidate()
            quickLookIndexObservation = nil
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            selectCurrentQuickLookIndex(in: panel)
            quickLookIndexObservation = panel.observe(\.currentPreviewItemIndex) { [weak self] panel, _ in
                self?.selectItemInActiveBrowser(at: panel.currentPreviewItemIndex)
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// All previewable items are the *whole current folder*, not just the
    /// selection — matching real Finder, where Quick Look's prev/next
    /// controls page through every file in the folder starting from
    /// whichever one was selected, rather than being limited to a
    /// single-item selection with nothing to page to.
    private func quickLookItems() -> [FileItem] {
        FileListing.contents(of: currentRootURL)
    }

    private func selectCurrentQuickLookIndex(in panel: QLPreviewPanel) {
        guard let selectedURL = activeBrowser.selectedURLs.first,
              let index = quickLookItems().firstIndex(where: { $0.url == selectedURL })
        else { return }
        panel.currentPreviewItemIndex = index
    }

    private func quickLookSelectionDidChange() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        selectCurrentQuickLookIndex(in: panel)
    }

    private func stepQuickLook(by delta: Int) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        let count = quickLookItems().count
        guard count > 0 else { return }
        let newIndex = min(max(panel.currentPreviewItemIndex + delta, 0), count - 1)
        panel.currentPreviewItemIndex = newIndex
        // The KVO observation above also calls this, but only when the
        // index actually changes — setting the same value at a boundary
        // (already at the first/last item) wouldn't otherwise re-sync.
        selectItemInActiveBrowser(at: newIndex)
    }

    private func selectItemInActiveBrowser(at index: Int) {
        let items = quickLookItems()
        guard index >= 0, index < items.count else { return }
        activeBrowser.selectItem(at: items[index].url)
    }

    // MARK: - Search

    private func setUpSearchField() {
        searchField.placeholderString = "Search This Folder"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.sendsSearchStringImmediately = true
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        if text.isEmpty {
            stopSearch()
        } else {
            startSearch(query: text)
        }
    }

    private func startSearch(query: String) {
        if viewModeBeforeSearch == nil {
            viewModeBeforeSearch = currentViewMode
            currentViewMode = .list
            showActiveViewController()
            viewModeControl.setSelected(true, forSegment: ViewMode.list.rawValue)
        }

        stopMetadataQuery()

        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [currentRootURL]
        metadataQuery.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", query)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchQueryDidUpdate),
            name: .NSMetadataQueryDidFinishGathering, object: metadataQuery
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchQueryDidUpdate),
            name: .NSMetadataQueryDidUpdate, object: metadataQuery
        )
        searchQuery = metadataQuery
        metadataQuery.start()
    }

    @objc private func searchQueryDidUpdate(_ notification: Notification) {
        guard let query = searchQuery else { return }
        query.disableUpdates()
        let results: [FileItem] = query.results.compactMap { result in
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { return nil }
            return FileItem(url: URL(fileURLWithPath: path))
        }
        query.enableUpdates()
        listVC.showSearchResults(results)
    }

    private func stopMetadataQuery() {
        if let query = searchQuery {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        }
        searchQuery = nil
    }

    private func stopSearch() {
        stopMetadataQuery()
        listVC.clearSearchResults()
        if let previous = viewModeBeforeSearch {
            currentViewMode = previous
            viewModeBeforeSearch = nil
            showActiveViewController()
            viewModeControl.setSelected(true, forSegment: previous.rawValue)
        }
    }

    private func showGetInfo(for fileItem: FileItem) {
        if let existing = getInfoWindows[fileItem.url] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = GetInfoWindowController(fileItem: fileItem)
        getInfoWindows[fileItem.url] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self] _ in
            self?.getInfoWindows.removeValue(forKey: fileItem.url)
        }
        controller.showWindow(nil)
    }

    private func showFileOperationError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "The operation couldn’t be completed."
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    /// Registers the inverse of an already-performed operation, and inside
    /// that inverse re-registers the original as its own inverse — the
    /// standard reversible-closure pattern, which gives redo for free and
    /// keeps this to the "simple, single-level" undo the project plan
    /// calls for (UndoManager's own chaining is all that's needed beyond
    /// that; no bespoke multi-step undo stack).
    private func registerUndo(actionName: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            undo()
            target.registerUndo(actionName: actionName, undo: redo, redo: undo)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - File menu actions
    // Public (rather than private, like the rest of this class's @objc
    // actions) so AppDelegate can wire NSMenuItems to them via a
    // compile-time-checked #selector across the module boundary, instead
    // of a stringly-typed Selector("newFolder:") that a rename could
    // silently break.

    @objc public func newFolder(_ sender: Any?) {
        let directory = activeBrowser.currentDirectoryURL
        do {
            let newURL = try FileOperations.createNewFolder(in: directory)
            refreshAllViews()
            registerUndo(
                actionName: "New Folder",
                undo: { [weak self] in
                    _ = try? FileOperations.moveToTrash(newURL)
                    self?.refreshAllViews()
                },
                redo: { [weak self] in
                    _ = try? FileOperations.createNewFolder(in: directory)
                    self?.refreshAllViews()
                }
            )
        } catch {
            showFileOperationError(error)
        }
    }

    @objc public func duplicateSelection(_ sender: Any?) {
        for url in activeBrowser.selectedURLs {
            do {
                let duplicateURL = try FileOperations.duplicate(url)
                registerUndo(
                    actionName: "Duplicate",
                    undo: { [weak self] in
                        _ = try? FileOperations.moveToTrash(duplicateURL)
                        self?.refreshAllViews()
                    },
                    redo: { [weak self] in
                        _ = try? FileOperations.duplicate(url)
                        self?.refreshAllViews()
                    }
                )
            } catch {
                showFileOperationError(error)
            }
        }
        refreshAllViews()
    }

    @objc public func moveSelectionToTrash(_ sender: Any?) {
        for url in activeBrowser.selectedURLs {
            do {
                let trashedURL = try FileOperations.moveToTrash(url)
                registerUndo(
                    actionName: "Move to Trash",
                    undo: { [weak self] in
                        _ = try? FileOperations.move(trashedURL, into: url.deletingLastPathComponent())
                        self?.refreshAllViews()
                    },
                    redo: { [weak self] in
                        _ = try? FileOperations.moveToTrash(url)
                        self?.refreshAllViews()
                    }
                )
            } catch {
                showFileOperationError(error)
            }
        }
        refreshAllViews()
    }

    @objc public func emptyTrash(_ sender: Any?) {
        do {
            try FileOperations.emptyTrash()
        } catch {
            showFileOperationError(error)
        }
    }

    @objc public func renameSelection(_ sender: Any?) {
        activeBrowser.beginRename()
    }

    @objc public func showInfoForSelection(_ sender: Any?) {
        guard let url = activeBrowser.selectedURLs.first else { return }
        showGetInfo(for: FileItem(url: url))
    }
}

extension MainWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(duplicateSelection(_:)), #selector(moveSelectionToTrash(_:)),
             #selector(renameSelection(_:)), #selector(showInfoForSelection(_:)):
            return !activeBrowser.selectedURLs.isEmpty
        case #selector(toggleQuickLook(_:)):
            return !activeBrowser.selectedURLs.isEmpty
        default:
            return true
        }
    }
}

extension MainWindowController: QLPreviewPanelDataSource {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems().count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookItems()[index].url as NSURL
    }
}

extension MainWindowController: QLPreviewPanelDelegate {}

private extension NSToolbarItem.Identifier {
    static let navigation = NSToolbarItem.Identifier("Navigation")
    static let viewMode = NSToolbarItem.Identifier("ViewMode")
    static let search = NSToolbarItem.Identifier("Search")
}

extension MainWindowController: NSToolbarDelegate {
    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Back/Forward"
            item.view = navigationControl
            return item
        case .viewMode:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "View"
            item.view = viewModeControl
            return item
        case .search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.view = searchField
            item.minSize = NSSize(width: 120, height: searchField.intrinsicContentSize.height)
            item.maxSize = NSSize(width: 240, height: searchField.intrinsicContentSize.height)
            return item
        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .flexibleSpace, .viewMode, .flexibleSpace, .search]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .viewMode, .search, .flexibleSpace]
    }
}
