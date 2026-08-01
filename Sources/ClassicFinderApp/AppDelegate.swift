import AppKit
import FSWindow

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snow Leopard predates Dark Mode; force the classic Aqua appearance
        // so all later custom drawing (sidebar gradients, etc.) has one
        // consistent baseline regardless of the host OS's current theme.
        NSApp.appearance = NSAppearance(named: .aqua)

        // Menu items target mainWindowController directly, so it has to
        // exist before setUpMainMenu() builds them.
        mainWindowController = MainWindowController()
        setUpMainMenu()
        mainWindowController.showWindow(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit ClassicFinder",
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

        NSApp.mainMenu = mainMenu
    }

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        let controller = mainWindowController as MainWindowController

        func addItem(_ title: String, action: Selector, keyEquivalent: String, modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            item.target = controller
            menu.addItem(item)
        }

        addItem("New Folder", action: #selector(MainWindowController.newFolder(_:)), keyEquivalent: "n", modifiers: [.command, .shift])
        menu.addItem(.separator())
        addItem("Get Info", action: #selector(MainWindowController.showInfoForSelection(_:)), keyEquivalent: "i")
        addItem("Quick Look", action: #selector(MainWindowController.toggleQuickLook(_:)), keyEquivalent: "y")
        addItem("Duplicate", action: #selector(MainWindowController.duplicateSelection(_:)), keyEquivalent: "d")
        addItem("Rename", action: #selector(MainWindowController.renameSelection(_:)), keyEquivalent: "\r", modifiers: [])
        menu.addItem(.separator())
        addItem("Move to Trash", action: #selector(MainWindowController.moveSelectionToTrash(_:)), keyEquivalent: "\u{8}")
        addItem("Empty Trash", action: #selector(MainWindowController.emptyTrash(_:)), keyEquivalent: "\u{8}", modifiers: [.command, .shift])
        return menu
    }

    private func makeEditMenu() -> NSMenu {
        // Standard Edit menu so text-field editing (rename, etc.) gets
        // working Cut/Copy/Paste/Undo/Redo via the normal responder chain
        // — without this, NSTextField editing sessions have no menu-driven
        // Cmd-Z/Cmd-C even though the key equivalents are handled by
        // AppKit automatically once the menu items exist.
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}
