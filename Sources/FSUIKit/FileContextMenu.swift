import AppKit
import FSCore

/// Shared right-click menu content for a single file/folder — used by
/// List, Icon, and (once it grows context-menu support) Column view, so
/// the item set stays consistent across view modes instead of drifting.
public enum FileContextMenu {
    public static func items(
        for fileItem: FileItem,
        onGetInfo: @escaping () -> Void,
        onRename: (() -> Void)?,
        onDuplicate: @escaping () -> Void,
        onMoveToTrash: @escaping () -> Void,
        onSetLabelColor: @escaping (LabelColor) -> Void,
        onOpenInNewWindow: (() -> Void)? = nil
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(ClosureMenuItem(title: NSLocalizedString("Get Info", comment: "右クリックメニュー: 情報を見る"), handler: onGetInfo))
        if fileItem.isBrowsable, let onOpenInNewWindow {
            items.append(ClosureMenuItem(
                title: NSLocalizedString("Open in New Window", comment: "右クリックメニュー: 別ウィンドウで開く"),
                handler: onOpenInNewWindow
            ))
        }
        if let onRename {
            items.append(ClosureMenuItem(title: NSLocalizedString("Rename", comment: "右クリックメニュー: 名称変更"), handler: onRename))
        }
        items.append(ClosureMenuItem(title: NSLocalizedString("Duplicate", comment: "右クリックメニュー: 複製"), handler: onDuplicate))
        items.append(.separator())

        let currentColor = fileItem.labelColor
        let colorMenu = NSMenu()
        for color in LabelColor.allCases {
            let item = ClosureMenuItem(title: color.displayName) { onSetLabelColor(color) }
            item.image = LabelSwatchImage.make(for: color, diameter: 12)
            item.state = currentColor == color ? .on : .off
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(
            title: NSLocalizedString("Color Label", comment: "右クリックメニュー: カラーラベルのサブメニュー"),
            action: nil, keyEquivalent: ""
        )
        colorItem.submenu = colorMenu
        items.append(colorItem)

        items.append(.separator())
        items.append(ClosureMenuItem(
            title: NSLocalizedString("Move to Trash", comment: "右クリックメニュー: ゴミ箱に入れる"),
            handler: onMoveToTrash
        ))

        return items
    }
}
