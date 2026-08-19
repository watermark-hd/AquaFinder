import AppKit
import FSCore
import FSWindow

final class AppDelegate: NSObject, NSApplicationDelegate, AppWindowOpening {
    // 複数ウィンドウ対応: 開いている全ての MainWindowController を保持する。
    // File/Edit/Go メニューの各アクションは target を nil のままにしてあり、
    // AppKit の標準レスポンダチェーン（firstResponder → … → window →
    // windowController → NSApp）経由で「今キーになっているウィンドウ」に
    // 自動的に届く。New Window だけはウィンドウ単位ではなくアプリ単位の
    // アクションなので、唯一 target を self（AppDelegate）に固定する。
    private var mainWindowControllers: [MainWindowController] = []
    // GetInfoWindowController と同様、使い回す単一インスタンス。
    private lazy var preferencesWindowController = PreferencesWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snow Leopard predates Dark Mode; force the classic Aqua appearance
        // so all later custom drawing (sidebar gradients, etc.) has one
        // consistent baseline regardless of the host OS's current theme.
        NSApp.appearance = NSAppearance(named: .aqua)

        setUpMainMenu()
        openNewWindow(rootURL: FileManager.default.homeDirectoryForCurrentUser)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 新規ウィンドウを1つ開く。File > New Window（常にホーム）と、フォルダの
    /// 右クリックメニュー「別ウィンドウで開く」（指定フォルダ）の両方から呼ばれる。
    func openNewWindow(rootURL: URL) {
        let controller = MainWindowController(rootURL: rootURL)
        if let frontWindow = mainWindowControllers.last?.window {
            // 2つ目以降は完全に重ならないよう少しずらして配置する。
            let cascadePoint = frontWindow.cascadeTopLeft(from: .zero)
            controller.window?.cascadeTopLeft(from: cascadePoint)
        }
        mainWindowControllers.append(controller)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.mainWindowControllers.removeAll { $0 === controller }
        }

        controller.showWindow(nil)
    }

    @objc private func newWindow(_ sender: Any?) {
        openNewWindow(rootURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc private func showPreferences(_ sender: Any?) {
        preferencesWindowController.showWindow(nil)
        preferencesWindowController.window?.makeKeyAndOrderFront(nil)
    }

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let preferencesItem = NSMenuItem(
            title: NSLocalizedString("Preferences…", comment: "アプリメニュー: 環境設定"),
            action: #selector(showPreferences(_:)), keyEquivalent: ","
        )
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(.separator())
        let quitFormat = NSLocalizedString("Quit %@", comment: "アプリメニュー: 終了（%@はアプリ名、翻訳しない）")
        appMenu.addItem(
            withTitle: String(format: quitFormat, "AquaFinder"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        fileMenuItem.submenu = makeFileMenu()

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = makeEditMenu()

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        viewMenuItem.submenu = makeViewMenu()

        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        goMenuItem.submenu = makeGoMenu()

        NSApp.mainMenu = mainMenu
    }

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("File", comment: "メニューバー: File"))

        // target は nil のまま — レスポンダチェーン経由で「今キーになっている
        // ウィンドウ」の MainWindowController に自動的に届く。単一インスタンスに
        // 固定していた旧実装は、複数ウィンドウ下では常に最初のウィンドウにしか
        // コマンドが効かない致命的なバグだった。
        func addItem(_ title: String, action: Selector, keyEquivalent: String, modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }

        let newWindowItem = NSMenuItem(
            title: NSLocalizedString("New Window", comment: "Fileメニュー: 新規ウィンドウ"),
            action: #selector(newWindow(_:)), keyEquivalent: "n"
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        addItem(
            NSLocalizedString("New Folder", comment: "Fileメニュー: 新規フォルダ"),
            action: #selector(MainWindowController.newFolder(_:)), keyEquivalent: "n", modifiers: [.command, .shift]
        )
        // Snow Leopard Finder's File menu has Open right after New Folder,
        // ahead of the separator before Get Info — matches that order.
        addItem(
            NSLocalizedString("Open", comment: "Fileメニュー: 開く"),
            action: #selector(MainWindowController.openSelection(_:)), keyEquivalent: "o"
        )
        menu.addItem(.separator())
        addItem(
            NSLocalizedString("Get Info", comment: "Fileメニュー: 情報を見る"),
            action: #selector(MainWindowController.showInfoForSelection(_:)), keyEquivalent: "i"
        )
        addItem(
            NSLocalizedString("Quick Look", comment: "Fileメニュー: クイックルック"),
            action: #selector(MainWindowController.toggleQuickLook(_:)), keyEquivalent: "y"
        )
        addItem(
            NSLocalizedString("Duplicate", comment: "Fileメニュー: 複製"),
            action: #selector(MainWindowController.duplicateSelection(_:)), keyEquivalent: "d"
        )
        addItem(
            NSLocalizedString("Rename", comment: "Fileメニュー: 名称変更"),
            action: #selector(MainWindowController.renameSelection(_:)), keyEquivalent: "\r", modifiers: []
        )
        menu.addItem(.separator())
        addItem(
            NSLocalizedString("Move to Trash", comment: "Fileメニュー: ゴミ箱に入れる"),
            action: #selector(MainWindowController.moveSelectionToTrash(_:)), keyEquivalent: "\u{8}"
        )
        addItem(
            NSLocalizedString("Empty Trash", comment: "Fileメニュー: ゴミ箱を空にする"),
            action: #selector(MainWindowController.emptyTrash(_:)), keyEquivalent: "\u{8}", modifiers: [.command, .shift]
        )
        menu.addItem(.separator())
        // NSWindow 自身が performClose(_:) を実装しているため、レスポンダ
        // チェーン経由で自動的に見つかる。
        addItem(
            NSLocalizedString("Close Window", comment: "Fileメニュー: ウィンドウを閉じる"),
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        return menu
    }

    /// "Arrange By" only affects Icon/Column view — List view sorts via
    /// its own clickable column headers, independently of this menu.
    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("View", comment: "メニューバー: View"))
        let arrangeMenu = NSMenu()
        for field in FileSortField.allCases {
            let item = NSMenuItem(
                title: field.displayName,
                action: #selector(MainWindowController.setSortField(_:)), keyEquivalent: ""
            )
            item.representedObject = field
            arrangeMenu.addItem(item)
        }
        let arrangeItem = NSMenuItem(
            title: NSLocalizedString("Arrange By", comment: "Viewメニュー: 整頓の基準サブメニュー"),
            action: nil, keyEquivalent: ""
        )
        arrangeItem.submenu = arrangeMenu
        menu.addItem(arrangeItem)
        return menu
    }

    private func makeGoMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Go", comment: "メニューバー: Go"))
        let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let item = NSMenuItem(
            title: NSLocalizedString("Enclosing Folder", comment: "Goメニュー: 上の階層のフォルダへ"),
            action: #selector(MainWindowController.goToEnclosingFolder(_:)),
            keyEquivalent: upArrow
        )
        item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)
        menu.addItem(.separator())
        let connectItem = NSMenuItem(
            title: NSLocalizedString("Connect to Server…", comment: "Goメニュー: サーバへ接続"),
            action: #selector(MainWindowController.connectToServer(_:)), keyEquivalent: "k"
        )
        menu.addItem(connectItem)
        return menu
    }

    private func makeEditMenu() -> NSMenu {
        // Standard Edit menu so text-field editing (rename, etc.) gets
        // working Cut/Copy/Paste/Undo/Redo via the normal responder chain
        // — without this, NSTextField editing sessions have no menu-driven
        // Cmd-Z/Cmd-C even though the key equivalents are handled by
        // AppKit automatically once the menu items exist.
        //
        // Copy/Paste の action セレクタは NSText.copy(_:)/paste(_:) と同名
        // ("copy:"/"paste:") を MainWindowController 側にも実装してあり、
        // テキスト編集中でなければファイルのコピー/貼り付けとしてそこまで
        // バブルアップする（MainWindowController.swift 参照）。
        let menu = NSMenu(title: NSLocalizedString("Edit", comment: "メニューバー: Edit"))
        menu.addItem(
            withTitle: NSLocalizedString("Undo", comment: "Editメニュー: 取り消す"),
            action: Selector(("undo:")), keyEquivalent: "z"
        )
        let redo = NSMenuItem(
            title: NSLocalizedString("Redo", comment: "Editメニュー: やり直す"),
            action: Selector(("redo:")), keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: NSLocalizedString("Cut", comment: "Editメニュー: カット"),
            action: #selector(NSText.cut(_:)), keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: NSLocalizedString("Copy", comment: "Editメニュー: コピー"),
            action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: NSLocalizedString("Paste", comment: "Editメニュー: ペースト"),
            action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: NSLocalizedString("Select All", comment: "Editメニュー: すべてを選択"),
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        return menu
    }
}
