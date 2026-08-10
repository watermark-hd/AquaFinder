import AppKit
import FSCore
import FSUIKit
import FSQuickLook

/// A single icon+label cell. Shows NSWorkspace's generic file icon
/// immediately, then upgrades to a real QuickLookThumbnailing-generated
/// content thumbnail (actual image contents, PDF first page, etc.) once
/// that async request finishes — the classic "placeholder, then upgrade"
/// pattern, needed because thumbnail generation is too slow to do
/// synchronously while scrolling.
final class IconCollectionViewItem: NSCollectionViewItem {
    /// Fired when the user commits an edit to the name field with a value
    /// that differs from the current name. The controller owns actually
    /// performing the rename (and reloading afterwards) since it's the one
    /// that knows about FileOperations and the full item list.
    var onCommitRename: ((FileItem, String) -> Void)?

    private var fileItem: FileItem?

    // NSCollectionViewItem tracks `isSelected` automatically but, unlike
    // NSTableView/NSOutlineView rows, draws no highlight of its own —
    // without this, clicking an icon selects it internally with no visible
    // feedback at all.
    private let selectionBackground = NSView()
    private let labelDot = NSImageView()

    override func loadView() {
        let container = NSView()

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.layer?.backgroundColor = NSColor.clear.cgColor
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown

        labelDot.translatesAutoresizingMaskIntoConstraints = false
        labelDot.isHidden = true

        let textField = NSTextField(labelWithString: "")
        textField.alignment = .center
        textField.font = NSFont.systemFont(ofSize: TextSize.medium.baseFontSize)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 2
        textField.translatesAutoresizingMaskIntoConstraints = false
        // Editing is only switched on for the duration of an explicit
        // rename (see beginEditing()) — NSCollectionView has no built-in
        // "click an already-selected item's label" gesture the way
        // NSTableView does, so leaving this always-editable would just
        // make stray clicks start typing into the label.
        textField.isEditable = false
        textField.delegate = self

        // Added first so it sits behind the icon/label (addSubview order
        // is z-order in AppKit).
        container.addSubview(selectionBackground)
        container.addSubview(imageView)
        container.addSubview(labelDot)
        container.addSubview(textField)

        NSLayoutConstraint.activate([
            selectionBackground.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            selectionBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            selectionBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            selectionBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 48),

            labelDot.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 2),
            labelDot.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            labelDot.widthAnchor.constraint(equalToConstant: 9),
            labelDot.heightAnchor.constraint(equalToConstant: 9),

            textField.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
        ])

        self.imageView = imageView
        self.textField = textField
        view = container
    }

    override var isSelected: Bool {
        didSet {
            selectionBackground.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
                : NSColor.clear.cgColor
        }
    }

    func configure(with fileItem: FileItem, textSize: TextSize) {
        self.fileItem = fileItem
        imageView?.image = IconCache.icon(for: fileItem.url)
        textField?.font = NSFont.systemFont(ofSize: textSize.baseFontSize)
        textField?.stringValue = fileItem.name
        textField?.isEditable = false

        let color = fileItem.labelColor
        labelDot.isHidden = color == .none
        labelDot.image = color == .none ? nil : LabelSwatchImage.make(for: color, diameter: 9)

        let requestedURL = fileItem.url
        ThumbnailLoader.thumbnail(for: requestedURL, size: CGSize(width: 48, height: 48), scale: 2) { [weak self] image in
            // The cell may have been recycled for a different item by the
            // time this async callback fires — only apply it if it's
            // still showing the URL that was requested.
            guard self?.fileItem?.url == requestedURL else { return }
            self?.imageView?.image = image
        }
    }

    func beginEditing() {
        textField?.isEditable = true
        view.window?.makeFirstResponder(textField)
        textField?.currentEditor()?.selectAll(nil)
    }
}

extension IconCollectionViewItem: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        textField?.isEditable = false
        guard let fileItem, let newName = textField?.stringValue else { return }
        onCommitRename?(fileItem, newName)
    }
}
