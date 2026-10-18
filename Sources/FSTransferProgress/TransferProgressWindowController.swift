import AppKit
import FSCore
import FSUIKit

/// A small classic-styled panel showing the running total for a batch of
/// copy/move operations — "Copying 3 of 12: photo.cr2", a glossy Aqua
/// progress bar, and a Stop button. Mirrors `GetInfoWindowController`'s
/// shape (code-built `NSPanel`, `.utilityWindow`, never released on close).
final class TransferProgressWindowController: NSWindowController {
    var onCancel: (() -> Void)?

    private let iconView = NSImageView()
    private let statusField = NSTextField(labelWithString: "")
    private let itemField = NSTextField(labelWithString: "")
    private let bar = ClassicAquaProgressBar()

    init(kind: DragOperationKind) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = kind == .copy
            ? NSLocalizedString("Copying", comment: "転送進捗パネルのタイトル: コピー中")
            : NSLocalizedString("Moving", comment: "転送進捗パネルのタイトル: 移動中")
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let window else { return }
        let contentView = window.contentView!

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = NSFont.systemFont(ofSize: 13)

        itemField.translatesAutoresizingMaskIntoConstraints = false
        itemField.font = NSFont.systemFont(ofSize: 11)
        itemField.textColor = .secondaryLabelColor
        itemField.lineBreakMode = .byTruncatingMiddle

        bar.translatesAutoresizingMaskIntoConstraints = false

        let stopButton = NSButton(
            title: NSLocalizedString("Stop", comment: "転送進捗パネル: 中止ボタン"),
            target: self, action: #selector(stopClicked)
        )
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.bezelStyle = .rounded

        contentView.addSubview(iconView)
        contentView.addSubview(statusField)
        contentView.addSubview(itemField)
        contentView.addSubview(bar)
        contentView.addSubview(stopButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            statusField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            statusField.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -2),
            statusField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            itemField.leadingAnchor.constraint(equalTo: statusField.leadingAnchor),
            itemField.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 2),
            itemField.trailingAnchor.constraint(equalTo: statusField.trailingAnchor),

            bar.leadingAnchor.constraint(equalTo: statusField.leadingAnchor),
            bar.topAnchor.constraint(equalTo: itemField.bottomAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: statusField.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 16),

            stopButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stopButton.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            stopButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    @objc private func stopClicked() {
        onCancel?()
    }

    /// `completedCount`/`totalCount` are 1-based ("item 3 of 12") so the
    /// status line never has to say "0 of 12" while the first file is
    /// still in flight.
    func update(icon: NSImage, itemName: String, completedCount: Int, totalCount: Int, fraction: Double) {
        iconView.image = icon
        let format = totalCount > 1
            ? NSLocalizedString("%d of %d items", comment: "転送進捗パネル: 件数表示（%d=現在, %d=合計）")
            : NSLocalizedString("1 item", comment: "転送進捗パネル: 件数表示（単数）")
        statusField.stringValue = totalCount > 1 ? String(format: format, completedCount, totalCount) : format
        itemField.stringValue = itemName
        bar.fractionCompleted = fraction
    }
}
