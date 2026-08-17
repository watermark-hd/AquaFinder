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
    /// 初回起動時（自動保存されたフレーム/サイドバー幅がまだ無いとき）の
    /// デフォルトサイズ。環境設定の「ウィンドウサイズを既定に戻す」からも使う。
    private static let defaultWindowSize = NSSize(width: 1075, height: 700)
    private static let defaultSidebarWidth: CGFloat = 150
    private static let windowFrameDefaultsKey = "AquaFinderMainWindowFrame"
    // Captured in init from the just-restored (or default) frame, and
    // re-applied once more in showWindow(_:) — see the doc comment there
    // for why a single re-assertion partway through init isn't enough.
    private var intendedWindowSize: NSSize = .zero

    private let sidebarVC = SidebarViewController()
    private let columnVC: ColumnBrowserViewController
    private let listVC: ListViewController
    private let iconVC: IconViewController
    private let contentContainer = ContentContainerViewController()
    private let statusBarView = StatusBarView(frame: .zero)

    private var historyStack: [URL] = []
    private var historyIndex = -1
    private var currentViewMode: ViewMode = ViewModePreferenceStore.loadViewMode()
    // Icon/Column view's "Arrange By" — List view sorts independently via
    // its own clickable column headers.
    private var sortField: FileSortField = ViewModePreferenceStore.loadSortField()
    private var currentRootURL: URL
    // Watches whichever folder is currently the window's root so changes
    // made outside the app (Terminal, another app, a second AquaFinder
    // window) show up without requiring a manual re-navigate. Scoped to
    // just currentRootURL — matches what List/Icon view actually display
    // and what the status bar's item count is based on.
    private let directoryWatcher = DirectoryWatcher()

    // Quick Look's spacebar shortcut isn't a standard NSMenuItem key
    // equivalent (plain space, no modifier), so it's caught with a local
    // event monitor scoped to this app's own windows instead. The same
    // monitor also drives Up/Down arrow-key navigation while the panel is
    // open — QLPreviewPanel only binds Left/Right itself, so Up/Down
    // otherwise silently does nothing while the panel is key.
    private var spacebarMonitor: Any?
    // テーマ／文字サイズが環境設定から変更されたときに全ビューへ反映する。
    private var appearanceObserver: NSObjectProtocol?
    private var resetLayoutObserver: NSObjectProtocol?
    // ウィンドウサイズのデフォルトへのリセット用（setUpContent で設定）。
    private weak var splitView: NSSplitView?
    // Keeps the browser's selection highlight following along as the
    // user steps through Quick Look — both our own Up/Down handling and
    // QLPreviewPanel's native Left/Right change this property, so
    // observing it (rather than hooking each navigation path separately)
    // covers both.
    private var quickLookIndexObservation: NSKeyValueObservation?
    // QLPreviewPanel.shared() apparently isn't a cheap accessor to call
    // repeatedly (it was being invoked on every single click via the
    // selection-change path just to check panel.isVisible, which made
    // ordinary icon selection feel delayed by up to ~1s). It's a genuine
    // singleton, so fetching it once and reusing the reference is safe.
    private lazy var quickLookPanel: QLPreviewPanel? = QLPreviewPanel.shared()
    // Tracked ourselves rather than reading panel.isVisible on every
    // selection change / arrow key, on the chance that property read has
    // its own non-trivial cost too — this way normal browsing (before
    // Quick Look has ever been opened) never touches `quickLookPanel` at
    // all, lazy-initializing it only the moment it's actually needed.
    private var isQuickLookVisible = false

    private let searchField = NSSearchField()
    private var searchQuery: NSMetadataQuery?

    private lazy var navigationControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["\u{25C0}", "\u{25B6}"],
            trackingMode: .momentary,
            target: self,
            action: #selector(navigationControlClicked(_:))
        )
        // .separated (the previous style) draws almost no bezel at rest,
        // so the button all but disappeared against the toolbar's own
        // light-gray background. .rounded gives each segment a visible
        // pill-shaped border and a subtle native shadow — a native
        // AppKit draw style, not a custom layer, so this costs nothing
        // beyond the style switch itself.
        control.segmentStyle = .rounded
        control.setEnabled(false, forSegment: 0)
        control.setEnabled(false, forSegment: 1)
        return control
    }()

    private lazy var viewModeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: [
                NSLocalizedString("Icon", comment: "表示切り替え: アイコン表示"),
                NSLocalizedString("List", comment: "表示切り替え: リスト表示"),
                NSLocalizedString("Column", comment: "表示切り替え: カラム表示"),
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(viewModeChanged(_:))
        )
        // See navigationControl above — left at the .automatic default
        // this blended into the toolbar the same way.
        control.segmentStyle = .rounded
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
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AquaFinder"
        // AppDelegate が NSApp.appearance を .aqua に固定していても、Apple
        // Silicon＋最近の macOS ではツールバー/タイトルバー付近の一部マテリアル
        // がシステムのダーク設定を拾ってしまうことがある。ウィンドウ単体にも
        // 明示的に appearance を指定し、常にライトな Aqua で描画させる。
        window.appearance = NSAppearance(named: .aqua)
        // Snow Leopard's window chrome was a continuous light-gray
        // gradient across titlebar + toolbar, not the modern flat-white
        // unified bar. Making the titlebar transparent lets the window's
        // own backgroundColor show through it; toolbarStyle .unified (11+)
        // keeps the toolbar strip in that same continuous surface instead
        // of drawing its own separate vibrancy material underneath.
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 640, height: 400)
        // NSWindow's own setFrameAutosaveName mechanism also saves the
        // frame automatically on its own, on window close — and that save
        // can capture a frame that's already been altered by the window's
        // own teardown (toolbar removal, etc.), silently overwriting the
        // correct value our own windowDidResize/windowDidMove save below.
        // Reading/writing a plain UserDefaults key ourselves avoids that
        // undocumented interference entirely.
        if let savedFrameString = UserDefaults.standard.string(forKey: Self.windowFrameDefaultsKey) {
            let savedFrame = NSRectFromString(savedFrameString)
            if savedFrame.width >= window.minSize.width, savedFrame.height >= window.minSize.height {
                window.setFrame(savedFrame, display: false)
            } else {
                window.setContentSize(Self.defaultWindowSize)
                window.center()
            }
        } else {
            window.setContentSize(Self.defaultWindowSize)
            window.center()
        }
        // The frame at this point is authoritative — either genuinely
        // restored from a prior launch, or the default just set above.
        let intendedWindowSize = window.frame.size

        super.init(window: window)
        self.intendedWindowSize = intendedWindowSize

        historyStack = [rootURL]
        historyIndex = 0

        setUpContent()
        // Installing the split view's contentViewController above runs an
        // Auto Layout pass that (for reasons not fully pinned down —
        // possibly the split view's content not yet having anything to
        // resolve a fitting size against) collapses the window down,
        // silently discarding whatever it was set to above. Re-assert
        // below, once showActiveViewController() has installed real
        // content too — that swap has its own fitting-size pass that can
        // just as easily re-shrink things right after this point.
        setUpToolbar()
        showActiveViewController()
        updateStatusBar()
        applyAppearancePreferences()
        iconVC.applySortField(sortField)
        columnVC.applySortField(sortField)
        directoryWatcher.onChange = { [weak self] in self?.refreshAllViews() }
        directoryWatcher.startWatching(rootURL)
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearancePreferencesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyAppearancePreferences()
        }
        resetLayoutObserver = NotificationCenter.default.addObserver(
            forName: .resetWindowLayoutRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resetToDefaultLayout()
        }

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
        columnVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }
        listVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }
        iconVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }
        sidebarVC.onFileSystemChange = { [weak self] in self?.refreshAllViews() }

        columnVC.onShowInfo = { [weak self] fileItem in self?.showGetInfo(for: fileItem) }
        listVC.onShowInfo = { [weak self] fileItem in self?.showGetInfo(for: fileItem) }
        iconVC.onShowInfo = { [weak self] fileItem in self?.showGetInfo(for: fileItem) }

        columnVC.onOpenInNewWindow = { [weak self] fileItem in self?.openInNewWindow(fileItem.url) }
        listVC.onOpenInNewWindow = { [weak self] fileItem in self?.openInNewWindow(fileItem.url) }
        iconVC.onOpenInNewWindow = { [weak self] fileItem in self?.openInNewWindow(fileItem.url) }

        listVC.onSelectionChange = { [weak self] in self?.quickLookSelectionDidChange() }
        iconVC.onSelectionChange = { [weak self] in self?.quickLookSelectionDidChange() }

        setUpSpacebarMonitor()
        setUpSearchField()

        // Assigned last, once the frame has fully settled from everything
        // above — those layout passes each resize the window in ways
        // that are legitimate mid-init but would corrupt the saved frame
        // (via windowDidResize/windowDidMove below) if persisted this early.
        window.delegate = self
    }

    /// AppDelegate calls this right after construction to actually put
    /// the window on screen. That on-screen presentation runs its own
    /// final Auto Layout pass — on top of the ones already chased during
    /// init (split view installation, toolbar attachment, swapping in the
    /// active browsing view) — that can *still* shrink the window down
    /// from what was restored/intended. This is the last point where a
    /// correction actually sticks.
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        if window.frame.width < intendedWindowSize.width || window.frame.height < intendedWindowSize.height {
            var frame = window.frame
            let centerX = frame.midX
            let centerY = frame.midY
            frame.size.width = max(frame.width, intendedWindowSize.width)
            frame.size.height = max(frame.height, intendedWindowSize.height)
            frame.origin = NSPoint(x: centerX - frame.width / 2, y: centerY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
    }

    deinit {
        if let spacebarMonitor {
            NSEvent.removeMonitor(spacebarMonitor)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let resetLayoutObserver {
            NotificationCenter.default.removeObserver(resetLayoutObserver)
        }
        quickLookIndexObservation?.invalidate()
        searchQuery?.stop()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpContent() {
        let splitVC = NSSplitViewController()

        // 通常の（"sidebar" マジックではない）SplitViewItem を使う。
        // sidebarWithViewController: が自動挿入するシステム標準の vibrancy
        // マテリアルは、ダークモード時に強制した Aqua 外観と噛み合わず、
        // サイドバー周囲に黒い縁取りが出てしまう不具合の原因だった。
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 120
        sidebarItem.maximumThickness = 220
        splitVC.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentContainer)
        splitVC.addSplitViewItem(contentItem)

        // ユーザーがドラッグで調整したサイドバー幅を次回起動時にも復元する。
        let hasSavedSidebarWidth = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplitView") != nil
        splitVC.splitView.autosaveName = "MainSplitView"
        self.splitView = splitVC.splitView
        if !hasSavedSidebarWidth {
            // 保存済みの幅がまだ無い初回は、明示的に小さめのデフォルト幅を
            // 設定する。この時点ではまだウィンドウに実フレームが無く
            // setPosition が効かないため、次のランループでレイアウト確定後に
            // 適用する。
            DispatchQueue.main.async { [weak self] in
                self?.splitView?.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
            }
        }

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
        // NSColor.textBackgroundColor.cgColor looks right in testing but is
        // a *dynamic* CGColor on modern macOS: CALayer.backgroundColor
        // re-resolves it against the layer's own live appearance rather
        // than freezing the color at assignment time, and that resolution
        // doesn't reliably respect the forced Aqua appearance — the same
        // failure mode already hit for the status bar, sidebar vibrancy,
        // and scroll view backgrounds. A fixed, non-dynamic near-white RGB
        // value sidesteps it entirely.
        rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1.0).cgColor
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
        directoryWatcher.startWatching(url)
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
        // ファイル操作（コピー/移動/リネーム/削除等）はどのディレクトリの
        // リスティングも古くする可能性があるため、個別のディレクトリだけを
        // 狙い撃ちせず全体を破棄する。3ビューとステータスバーがこの直後に
        // それぞれ再取得するので、実際に再読み込みされるのは画面に必要な
        // 範囲だけに収まる。
        DirectoryListingCache.invalidateAll()
        columnVC.refresh()
        listVC.refresh()
        iconVC.refresh()
        updateStatusBar()
    }

    private func updateStatusBar() {
        let count = DirectoryListingCache.contents(of: currentRootURL).count
        statusBarView.update(itemCount: count, directoryURL: currentRootURL)
    }

    /// 環境設定（テーマ／文字サイズ）を読み直し、ウィンドウ本体と全ての
    /// 子ビューへ反映する。初期化時と、環境設定パネルでの変更通知の両方
    /// から呼ばれる。
    private func applyAppearancePreferences() {
        let theme = AppearancePreferenceStore.theme
        let textSize = AppearancePreferenceStore.textSize

        switch theme {
        case .graphite10_6:
            window?.backgroundColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)
        case .metal10_4:
            window?.backgroundColor = MetalTexture.backgroundColor
        }
        statusBarView.applyTheme(theme)
        sidebarVC.applyTheme(theme)

        statusBarView.applyTextSize(textSize)
        sidebarVC.applyTextSize(textSize)
        listVC.applyTextSize(textSize)
        iconVC.applyTextSize(textSize)
        columnVC.applyTextSize(textSize)
    }

    /// 環境設定パネルの「ウィンドウサイズを既定に戻す」から呼ばれる。
    /// ウィンドウ枠・サイドバー幅ともに自動保存が有効なので、ここでの
    /// リサイズがそのまま次回起動時の初期値としても引き継がれる。
    private func resetToDefaultLayout() {
        if let window {
            let newSize = Self.defaultWindowSize
            var frame = window.frame
            let centerX = frame.midX
            let centerY = frame.midY
            frame.size = newSize
            frame.origin = NSPoint(x: centerX - newSize.width / 2, y: centerY - newSize.height / 2)
            // Not animated: an animated resize runs asynchronously, so
            // window.frame (and the frame the windowDidResize-triggered
            // autosave below captures) wouldn't reliably reflect the
            // final, fully-settled size at the moment this method returns.
            window.setFrame(frame, display: true, animate: false)
        }
        splitView?.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
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

            if event.keyCode == 125 || event.keyCode == 126, self.isQuickLookVisible { // down / up
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
        guard let panel = quickLookPanel else { return }
        if isQuickLookVisible {
            panel.orderOut(nil)
            isQuickLookVisible = false
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
            isQuickLookVisible = true
        }
    }

    /// All previewable items are the *whole current folder*, not just the
    /// selection — matching real Finder, where Quick Look's prev/next
    /// controls page through every file in the folder starting from
    /// whichever one was selected, rather than being limited to a
    /// single-item selection with nothing to page to.
    private func quickLookItems() -> [FileItem] {
        DirectoryListingCache.contents(of: currentRootURL)
    }

    private func selectCurrentQuickLookIndex(in panel: QLPreviewPanel) {
        guard let selectedURL = activeBrowser.selectedURLs.first,
              let index = quickLookItems().firstIndex(where: { $0.url == selectedURL })
        else { return }
        panel.currentPreviewItemIndex = index
    }

    private func quickLookSelectionDidChange() {
        // isQuickLookVisible short-circuits *before* ever touching
        // quickLookPanel — during ordinary browsing (Quick Look never
        // opened this session), this function must do zero QuickLook-
        // related work, full stop, since it runs on every single
        // selection change including arrow-key navigation.
        guard isQuickLookVisible, let panel = quickLookPanel else { return }
        selectCurrentQuickLookIndex(in: panel)
    }

    private func stepQuickLook(by delta: Int) {
        guard isQuickLookVisible, let panel = quickLookPanel else { return }
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
        searchField.placeholderString = NSLocalizedString("Search This Folder", comment: "検索フィールドのプレースホルダー")
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
        columnVC.showSearchResults(results)
        listVC.showSearchResults(results)
        iconVC.showSearchResults(results)
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
        columnVC.clearSearchResults()
        listVC.clearSearchResults()
        iconVC.clearSearchResults()
    }

    private func showGetInfo(for fileItem: FileItem) {
        GetInfoWindowRegistry.shared.show(for: fileItem)
    }

    private func showFileOperationError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("The operation couldn’t be completed.", comment: "ファイル操作失敗時のアラートタイトル")
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
                actionName: NSLocalizedString("New Folder", comment: "取り消し操作名: 新規フォルダ"),
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
                    actionName: NSLocalizedString("Duplicate", comment: "取り消し操作名: 複製"),
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
                    actionName: NSLocalizedString("Move to Trash", comment: "取り消し操作名: ゴミ箱に入れる"),
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
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Are you sure you want to permanently erase the items in the Trash?",
            comment: "ゴミ箱を空にする確認ダイアログのタイトル"
        )
        alert.informativeText = NSLocalizedString(
            "You can’t undo this action.",
            comment: "ゴミ箱を空にする確認ダイアログの説明"
        )
        // Matches real Finder: "Empty Trash" is the default button (plain
        // Return activates it), "Cancel" is reachable via Escape.
        alert.addButton(withTitle: NSLocalizedString("Empty Trash", comment: "ゴミ箱を空にする確認ダイアログ: 実行ボタン"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "ゴミ箱を空にする確認ダイアログ: キャンセルボタン"))

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try FileOperations.emptyTrash()
            } catch {
                self?.showFileOperationError(error)
            }
        }
    }

    @objc public func renameSelection(_ sender: Any?) {
        activeBrowser.beginRename()
    }

    @objc public func showInfoForSelection(_ sender: Any?) {
        let urls = activeBrowser.selectedURLs
        if urls.count > 1 {
            GetInfoWindowRegistry.shared.showMultiple(for: urls.map { FileItem(url: $0) })
        } else if let url = urls.first {
            showGetInfo(for: FileItem(url: url))
        }
    }

    // MARK: - Go menu actions

    @objc public func goToEnclosingFolder(_ sender: Any?) {
        let parent = currentRootURL.deletingLastPathComponent()
        guard parent.path != currentRootURL.path else { return }
        navigate(to: parent, pushHistory: true)
    }

    @objc public func connectToServer(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Connect to Server", comment: "サーバへ接続ダイアログのタイトル")
        alert.informativeText = NSLocalizedString(
            "Enter the server address.", comment: "サーバへ接続ダイアログの説明"
        )
        let addressField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        addressField.placeholderString = "smb://server/share"
        alert.accessoryView = addressField
        alert.window.initialFirstResponder = addressField
        alert.addButton(withTitle: NSLocalizedString("Connect", comment: "サーバへ接続ダイアログ: 接続ボタン"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "サーバへ接続ダイアログ: キャンセルボタン"))

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return }
            self?.performServerConnect(address)
        }
    }

    /// NetFSMountURLSync blocks (network round-trip, possibly a system
    /// auth prompt) — run it off the main thread so the UI stays
    /// responsive, then hop back for the sidebar refresh and navigation.
    private func performServerConnect(_ address: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let mountedURLs = try ServerConnection.connect(to: address)
                DispatchQueue.main.async {
                    self?.sidebarVC.refreshVolumeSections()
                    if let firstURL = mountedURLs.first {
                        self?.navigate(to: firstURL, pushHistory: true)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showFileOperationError(error)
                }
            }
        }
    }

    // MARK: - View menu actions

    /// Icon/Column view's "Arrange By" — List view sorts independently
    /// via its own clickable column headers, so this only ever touches
    /// the other two.
    @objc public func setSortField(_ sender: Any?) {
        guard let field = (sender as? NSMenuItem)?.representedObject as? FileSortField else { return }
        sortField = field
        ViewModePreferenceStore.saveSortField(field)
        iconVC.applySortField(field)
        columnVC.applySortField(field)
    }

    // MARK: - File copy / paste (⌘C / ⌘V)
    //
    // Edit メニューの Copy/Paste 項目は NSText.copy(_:)/paste(_:) と同名
    // ("copy:"/"paste:") の target なしアクションで、テキスト編集中は NSText
    // 側が先にレスポンダチェーンで見つかる。ここで同名セレクタを実装する
    // ことで、テキストフィールド編集中でなければ（＝ファイルブラウザに
    // フォーカスがあれば）ここまでバブルアップしてファイルのコピー/貼り付け
    // として扱われる。

    @objc public func copy(_ sender: Any?) {
        let urls = activeBrowser.selectedURLs
        guard !urls.isEmpty else { return }
        FilePasteboard.write(urls)
    }

    @objc public func paste(_ sender: Any?) {
        let sourceURLs = FilePasteboard.readURLs()
        guard !sourceURLs.isEmpty else { return }
        let destinationDirectory = activeBrowser.currentDirectoryURL
        var pastedURLs: [URL] = []
        for sourceURL in sourceURLs {
            if let pastedURL = try? FileOperations.copy(sourceURL, into: destinationDirectory) {
                pastedURLs.append(pastedURL)
            }
        }
        guard !pastedURLs.isEmpty else { return }
        refreshAllViews()
        registerUndo(
            actionName: NSLocalizedString("Paste", comment: "取り消し操作名: 貼り付け"),
            undo: { [weak self] in
                for url in pastedURLs {
                    _ = try? FileOperations.moveToTrash(url)
                }
                self?.refreshAllViews()
            },
            redo: { [weak self] in
                for sourceURL in sourceURLs {
                    _ = try? FileOperations.copy(sourceURL, into: destinationDirectory)
                }
                self?.refreshAllViews()
            }
        )
    }

    // MARK: - Open in New Window

    /// フォルダの右クリックメニュー「別ウィンドウで開く」から呼ばれる。
    /// AppDelegate がウィンドウ一覧を一元管理しているので、そちらに委譲する。
    func openInNewWindow(_ url: URL) {
        (NSApp.delegate as? AppWindowOpening)?.openNewWindow(rootURL: url)
    }
}

/// AppDelegate（AquaFinderApp モジュール）へ直接依存せずに新規ウィンドウを
/// 開くための最小限のプロトコル。AppDelegate 側でこれに準拠させる。
public protocol AppWindowOpening: AnyObject {
    func openNewWindow(rootURL: URL)
}

extension MainWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(duplicateSelection(_:)), #selector(moveSelectionToTrash(_:)),
             #selector(renameSelection(_:)), #selector(showInfoForSelection(_:)):
            return !activeBrowser.selectedURLs.isEmpty
        case #selector(toggleQuickLook(_:)):
            return !activeBrowser.selectedURLs.isEmpty
        case #selector(goToEnclosingFolder(_:)):
            return currentRootURL.deletingLastPathComponent().path != currentRootURL.path
        case #selector(copy(_:)):
            return !activeBrowser.selectedURLs.isEmpty
        case #selector(paste(_:)):
            return !FilePasteboard.readURLs().isEmpty
        case #selector(setSortField(_:)):
            menuItem.state = (menuItem.representedObject as? FileSortField) == sortField ? .on : .off
            return true
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

extension MainWindowController: NSWindowDelegate {
    public func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    public func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    private func saveWindowFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.windowFrameDefaultsKey)
    }
}

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
            item.label = NSLocalizedString("Back/Forward", comment: "ツールバー項目: 進む/戻るボタン")
            item.view = navigationControl
            return item
        case .viewMode:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("View", comment: "ツールバー項目: 表示切り替え")
            item.view = viewModeControl
            return item
        case .search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Search", comment: "ツールバー項目: 検索")
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
