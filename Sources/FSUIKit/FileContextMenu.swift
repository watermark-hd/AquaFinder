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
        onSetLabelColor: @escaping (LabelColor) -> Void
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(ClosureMenuItem(title: "Get Info", handler: onGetInfo))
        if let onRename {
            items.append(ClosureMenuItem(title: "Rename", handler: onRename))
        }
        items.append(ClosureMenuItem(title: "Duplicate", handler: onDuplicate))
        items.append(.separator())

        let currentColor = fileItem.labelColor
        let colorMenu = NSMenu()
        for color in LabelColor.allCases {
            let item = ClosureMenuItem(title: color.localizedName) { onSetLabelColor(color) }
            item.image = LabelSwatchImage.make(for: color, diameter: 12)
            item.state = currentColor == color ? .on : .off
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color Label", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        items.append(colorItem)

        items.append(.separator())
        items.append(ClosureMenuItem(title: "Move to Trash", handler: onMoveToTrash))

        return items
    }
}
