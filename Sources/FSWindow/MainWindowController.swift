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

    // A custom label rather than the window's own title: AppKit
    // positions the native title itself (roughly centered across the
    // toolbar's real NSToolbarItems), with no awareness of the floating
    // nav/view-mode buttons layered on top of the toolbar outside that
    // system — for some folder-name lengths it lands the title text
    // right underneath navigationControl. A plain label pinned exactly
    // where we want it sidesteps that entirely.
    private let folderNameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.boldSystemFont(ofSize: 13)
        label.textColor = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var navigationControl: ClassicSegmentedControl = {
        let control = ClassicSegmentedControl(
            labels: ["\u{25C0}", "\u{25B6}"],
            trackingMode: .momentary,
            target: self,
            action: #selector(navigationControlClicked(_:))
        )
        control.setEnabled(false, forSegment: 0)
        control.setEnabled(false, forSegment: 1)
        return control
    }()

    private lazy var viewModeControl: ClassicSegmentedControl = {
        let control = ClassicSegmentedControl(
            labels: [
                NSLocalizedString("Icon", comment: "表示切り替え: アイコン表示"),
                NSLocalizedString("List", comment: "表示切り替え: リスト表示"),
                NSLocalizedString("Column", comment: "表示切り替え: カラム表示"),
            ],
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
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AquaFinder"
        // The visible folder name is drawn by folderNameLabel instead
        // (see its own doc comment for why) — `title` itself stays set
        // so Mission Control/Window menu/VoiceOver still have something
        // meaningful, it just never gets painted into the toolbar.
        window.titleVisibility = .hidden
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
        updateWindowTitle()
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
        setUpFloatingToolbarButtons()

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
        // NOT called from here — setUpFloatingToolbarButtons() pins
        // viewModeControl to searchField, and searchField doesn't get
        // its own superview (as the search toolbar item's view) until
        // setUpSearchField() runs later in init. Activating a
        // cross-hierarchy constraint against a view with no superview
        // yet throws immediately, crashing on launch before the window
        // ever appears. See the call in init, after setUpSearchField().
    }

    // navigationControl/viewModeControl used to be NSToolbarItems, then
    // NSTitlebarAccessoryViewControllers — see the comment on
    // toolbarDefaultItemIdentifiers below for why neither worked out.
    // Titlebar accessories specifically never appeared at all: with
    // titlebarAppearsTransparent + .unified merging the titlebar and
    // toolbar into one continuous strip, there's no separate titlebar
    // region left for an accessory to actually occupy.
    //
    // Adding the controls directly as subviews of the window's root
    // frame view (contentView's own superview, which spans the full
    // window including the area behind the toolbar) sidesteps both
    // toolbar-hosting mechanisms entirely. contentView's superview is
    // technically an AppKit implementation detail (NSThemeFrame), but
    // adding a subview to whatever view that happens to be is ordinary
    // public NSView API, not private API use.
    //
    // Positioning them is plain frame math (updateFloatingToolbarButtonFrames
    // below), not Auto Layout constraints — Auto Layout constraints
    // anchored to rootView's leading/trailing (even at .defaultHigh, not
    // required priority) fed straight into how NSWindow computes its own
    // live-resize minimum: confirmed by isolating it, live-resizing the
    // window narrower silently refused to go below whatever width it
    // happened to be at, in both directions, even though nothing had an
    // actual lower bound anywhere near that width. Plain frame
    // assignment doesn't touch NSWindow's constraint-based sizing at
    // all, so it can't trigger that regardless of priority.
    private func setUpFloatingToolbarButtons() {
        guard let rootView = window?.contentView?.superview else { return }
        rootView.addSubview(navigationControl)
        rootView.addSubview(viewModeControl)
        rootView.addSubview(folderNameLabel)
        updateFloatingToolbarButtonFrames()
    }

    /// Called once from setUpFloatingToolbarButtons and again from
    /// windowDidResize below, since these three views are positioned by
    /// hand rather than kept in place by Auto Layout.
    private func updateFloatingToolbarButtonFrames() {
        guard let rootView = window?.contentView?.superview else { return }
        let rootBounds = rootView.bounds
        let top: CGFloat = 10

        var navFrame = navigationControl.frame
        navFrame.origin = NSPoint(x: 78, y: rootBounds.height - top - navFrame.height)
        navigationControl.frame = navFrame

        // viewModeControl sits just left of where the search field
        // usually ends up (its own .search toolbar item has maxSize
        // width 240, plus the toolbar's own trailing margin) — not
        // pinned to searchField directly: NSToolbarItemViewer explicitly
        // refuses to host a layout engine touched by constraints from
        // outside the item's own view ("failed to host an autolayout
        // engine... constraints [that] reference views outside of the
        // item.view"), throwing immediately and crashing before the
        // window ever appears. A fixed offset from the right edge
        // sidesteps that entirely, at the cost of not perfectly tracking
        // the search field if it's ever narrower than its max.
        var viewModeFrame = viewModeControl.frame
        viewModeFrame.origin = NSPoint(
            x: rootBounds.width - 270 - viewModeFrame.width,
            y: rootBounds.height - top - viewModeFrame.height
        )
        viewModeControl.frame = viewModeFrame

        let labelWidth = min(
            folderNameLabel.intrinsicContentSize.width,
            max(0, viewModeFrame.minX - 16 - (navFrame.maxX + 16))
        )
        folderNameLabel.frame = NSRect(
            x: (rootBounds.width - labelWidth) / 2,
            y: navFrame.midY - folderNameLabel.intrinsicContentSize.height / 2,
            width: labelWidth,
            height: folderNameLabel.intrinsicContentSize.height
        )
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
        updateWindowTitle()
    }

    /// Real Finder shows the current folder's name in the title bar —
    /// `FileManager.displayName` gives the same localized names it uses
    /// there ("デスクトップ" rather than the raw "Desktop" path
    /// component, etc.). Sits in the toolbar's center now that the
    /// view-mode control moved next to the search field instead.
    private func updateWindowTitle() {
        let name = FileManager.default.displayName(atPath: currentRootURL.path)
        window?.title = name
        folderNameLabel.stringValue = name
    }

    @objc private func navigationControlClicked(_ sender: ClassicSegmentedControl) {
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

    @objc private func viewModeChanged(_ sender: ClassicSegmentedControl) {
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
        updateFloatingToolbarButtonFrames()
    }

    public func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    private func saveWindowFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.windowFrameDefaultsKey)
    }
}

/// Fully custom-drawn stand-in for NSSegmentedControl, used only for the
/// toolbar's back/forward and view-mode buttons.
///
/// Three earlier attempts all tried to keep using the real
/// NSSegmentedControl and just decorate it: setting `wantsLayer = true`
/// directly on the control to draw a CALayer border on top broke its own
/// native cell drawing on one Mac (flat dark gray fill instead of the
/// system pill background) and had corner-radius timing bugs of its
/// own; moving that border onto a separate wrapper view fixed both, but
/// the *shape and fill color* underneath were still whatever
/// `.rounded`'s native bezel happens to be — and that turns out to
/// differ a lot by macOS version (a pale full pill on newer macOS, a
/// more rectangular, more visibly gray-filled shape on Ventura). There's
/// no native segment style that renders identically, let alone matches
/// Snow Leopard's actual look, on every version. Drawing the whole
/// button by hand — shape, fill, divider, selection highlight, soft
/// shadow — sidesteps all of that: it looks the same everywhere because
/// none of it depends on system chrome. Uses fixed, non-dynamic grays
/// throughout (see rootView's own layer-color comment elsewhere in this
/// file for why dynamic system colors are avoided).
private final class ClassicSegmentedControl: NSView {
    enum Tracking { case momentary, selectOne }

    private let labels: [String]
    private var enabledFlags: [Bool]
    private let tracking: Tracking
    weak var target: AnyObject?
    var action: Selector?
    /// For .selectOne, the persisted selection. For .momentary, only
    /// meaningful transiently: set right before the action fires so the
    /// handler can read which segment was clicked (mirrors
    /// NSSegmentedControl's own momentary behavior), then never used for
    /// drawing since momentary buttons don't stay highlighted.
    private(set) var selectedSegment: Int = -1
    private var pressedIndex: Int?

    // Was 5 (too round, read as a pill) then 2 (a bit too sharp per
    // feedback) — 4 is a light touch of softening on a still-clearly
    // square button.
    private static let cornerRadius: CGFloat = 4
    // srgb, not calibratedWhite — calibratedWhite resolves through the
    // "Generic Gray"/display-calibration color space, so the exact same
    // value can render at a visibly different brightness on two Macs
    // with different display profiles. srgb is a fixed, absolute space:
    // what's specified here is what gets drawn, on any display.
    private static let shadowColor = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 0.85)
    // A hair off pure white reads as more "retro" than a flat white fill.
    private static let fillColor = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
    private static let selectedFillColor = NSColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1.0)
    private static let dividerColor = NSColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1.0)
    private static let textColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    private static let disabledTextColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 0.35)
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let horizontalPadding: CGFloat = 14
    private static let minSegmentWidth: CGFloat = 28
    private static let shapeHeight: CGFloat = 22
    /// Room around the drawn shape for the shadow's blur to spread into.
    /// NSView drawing is always clipped to the view's own bounds, so if
    /// this is smaller than the blur radius below, the blur gets cut off
    /// hard right at that rectangular bounds edge before it can fully
    /// fade out — visible as a faint straight-edged rectangle boxing in
    /// the actually-rounded button. Needs to comfortably exceed
    /// shadowBlurRadius, not just be nonzero.
    private static let shadowMargin: CGFloat = 5

    init(labels: [String], trackingMode: Tracking, target: AnyObject?, action: Selector?) {
        self.labels = labels
        self.enabledFlags = Array(repeating: true, count: labels.count)
        self.tracking = trackingMode
        self.target = target
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Relying on intrinsicContentSize alone left this at the mercy
        // of however NSToolbarItem resolves a custom view's size — which
        // turned out not to be consistent: on at least one Mac the item
        // collapsed down to something closer to square than the actual
        // multi-segment width, squashing every segment's divider/text
        // into a sliver in the middle of what read as a plain rounded
        // (near-circular) box. Explicit constraints pin the real size
        // directly, leaving nothing for the toolbar to get wrong. Labels
        // never change after init, so this only needs to happen once.
        let size = intrinsicContentSize
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool, forSegment segment: Int) {
        selectedSegment = selected ? segment : (selectedSegment == segment ? -1 : selectedSegment)
        needsDisplay = true
    }

    func setEnabled(_ enabled: Bool, forSegment segment: Int) {
        enabledFlags[segment] = enabled
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let width = segmentWidths.reduce(0, +) + Self.shadowMargin * 2
        return NSSize(width: width, height: Self.shapeHeight + Self.shadowMargin * 2)
    }

    private var segmentWidths: [CGFloat] {
        labels.map { label in
            let size = (label as NSString).size(withAttributes: [.font: Self.font])
            return max(size.width + Self.horizontalPadding * 2, Self.minSegmentWidth)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let widths = segmentWidths
        let rect = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        // The button's own soft shadow — see the class doc comment for
        // why this is a hand-drawn blur rather than a native bezel.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Self.shadowColor
        shadow.shadowBlurRadius = 1.0
        shadow.shadowOffset = .zero
        shadow.set()
        Self.fillColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var x = rect.minX
        for (i, width) in widths.enumerated() {
            let segmentRect = NSRect(x: x, y: rect.minY, width: width, height: rect.height)
            // Now that the outer shape itself is nearly square
            // (cornerRadius above), a plain full-bleed rectangle here
            // matches it — no more mismatch between a round outer edge
            // and a square inner highlight, so no inset trick needed.
            if tracking == .selectOne, selectedSegment == i {
                Self.selectedFillColor.setFill()
                segmentRect.fill()
            } else if pressedIndex == i {
                Self.selectedFillColor.withAlphaComponent(0.5).setFill()
                segmentRect.fill()
            }
            if i > 0 {
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: x, y: rect.minY + 3))
                divider.line(to: NSPoint(x: x, y: rect.maxY - 3))
                divider.lineWidth = 1
                Self.dividerColor.setStroke()
                divider.stroke()
            }
            let color = enabledFlags[i] ? Self.textColor : Self.disabledTextColor
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            let labelString = labels[i] as NSString
            let labelSize = labelString.size(withAttributes: attrs)
            labelString.draw(
                at: NSPoint(x: segmentRect.midX - labelSize.width / 2, y: segmentRect.midY - labelSize.height / 2),
                withAttributes: attrs
            )
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentIndex(at: point), enabledFlags[index] else { return }
        pressedIndex = index
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedIndex = nil; needsDisplay = true }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentIndex(at: point), index == pressedIndex, enabledFlags[index] else { return }
        selectedSegment = index
        if let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func segmentIndex(at point: NSPoint) -> Int? {
        var x = Self.shadowMargin
        for (i, width) in segmentWidths.enumerated() {
            if point.x >= x, point.x < x + width { return i }
            x += width
        }
        return nil
    }
}

private extension NSToolbarItem.Identifier {
    static let search = NSToolbarItem.Identifier("Search")
}

extension MainWindowController: NSToolbarDelegate {
    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
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

    // navigationControl and viewModeControl used to be .navigation/.viewMode
    // NSToolbarItems here. Any NSToolbarItem given a custom `view` gets
    // wrapped by AppKit in a private NSToolbarItemViewer that clips it to
    // a rounded-pill mask via raw Quartz drawing — invisible to every
    // public layer/mask/isBordered/toolbarStyle property, and with no
    // documented way to opt out. They're floated over the window's root
    // frame view instead now (see setUpFloatingToolbarButtons) — search
    // is the only thing left that still needs to be a real toolbar item.
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .search]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.search, .flexibleSpace]
    }
}
