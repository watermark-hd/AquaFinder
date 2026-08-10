import AppKit
import FSCore
import FSUIKit

/// A single item's Get Info panel: icon/name, the 7 label-color swatches,
/// and one collapsible "General" section (Kind/Size/Where/Created/
/// Modified). Real Snow Leopard Get Info also has More Info, Name &
/// Extension, Open With, and Sharing & Permissions sections — those are
/// deliberately not implemented yet (a scope trim for this phase, not a
/// silent omission) since General covers what's actually looked at most.
public final class GetInfoWindowController: NSWindowController {
    private let fileItem: FileItem
    private let sizeCalculator = FolderSizeCalculator()

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private var swatches: [ColorSwatchView] = []

    private let disclosureButton = NSButton()
    private let generalContentView = NSStackView()

    private let kindValueField = NSTextField(labelWithString: "")
    private let sizeValueField = NSTextField(labelWithString: "")
    private let whereValueField = NSTextField(labelWithString: "")
    private let createdValueField = NSTextField(labelWithString: "")
    private let modifiedValueField = NSTextField(labelWithString: "")

    public init(fileItem: FileItem) {
        self.fileItem = fileItem
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let titleFormat = NSLocalizedString("%@ Info", comment: "Get Info パネルのタイトル（%@=ファイル名）")
        panel.title = String(format: titleFormat, fileItem.name)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        buildUI()
        populate()
        if fileItem.isBrowsable {
            sizeValueField.stringValue = NSLocalizedString("Calculating…", comment: "フォルダサイズ計算中の表示")
            sizeCalculator.calculate(fileItem.url) { [weak self] bytes in
                self?.sizeValueField.stringValue = ByteCountFormatter.getInfo.string(fromByteCount: bytes)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        sizeCalculator.cancel()
    }

    private func buildUI() {
        guard let window else { return }

        iconView.image = IconCache.icon(for: fileItem.url)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = NSFont.boldSystemFont(ofSize: 13)
        nameField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [iconView, nameField])
        headerStack.orientation = .vertical
        headerStack.spacing = 6
        headerStack.alignment = .centerX
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let swatchRow = NSStackView(views: LabelColor.allCases.map { color in
            let swatch = ColorSwatchView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            swatch.widthAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.color = color
            swatch.onClick = { [weak self] in self?.applyLabelColor(color) }
            swatches.append(swatch)
            return swatch
        })
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 4

        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.title = ""
        disclosureButton.state = .on
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleGeneralSection)

        let generalLabel = NSTextField(labelWithString: NSLocalizedString("General", comment: "Get Info パネル: 一般セクションの見出し"))
        generalLabel.font = NSFont.boldSystemFont(ofSize: 11)

        let generalHeaderRow = NSStackView(views: [disclosureButton, generalLabel])
        generalHeaderRow.orientation = .horizontal
        generalHeaderRow.spacing = 2
        generalHeaderRow.alignment = .centerY

        generalContentView.orientation = .vertical
        generalContentView.alignment = .leading
        generalContentView.spacing = 4
        generalContentView.addArrangedSubview(makeRow(
            label: NSLocalizedString("Kind:", comment: "Get Info パネル: 種類のラベル"), value: kindValueField
        ))
        generalContentView.addArrangedSubview(makeRow(
            label: NSLocalizedString("Size:", comment: "Get Info パネル: サイズのラベル"), value: sizeValueField
        ))
        generalContentView.addArrangedSubview(makeRow(
            label: NSLocalizedString("Where:", comment: "Get Info パネル: 場所のラベル"), value: whereValueField
        ))
        generalContentView.addArrangedSubview(makeRow(
            label: NSLocalizedString("Created:", comment: "Get Info パネル: 作成日のラベル"), value: createdValueField
        ))
        generalContentView.addArrangedSubview(makeRow(
            label: NSLocalizedString("Modified:", comment: "Get Info パネル: 変更日のラベル"), value: modifiedValueField
        ))

        let mainStack = NSStackView(views: [headerStack, swatchRow, NSBox.separatorBox(), generalHeaderRow, generalContentView])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        swatchRow.widthAnchor.constraint(lessThanOrEqualTo: mainStack.widthAnchor).isActive = true

        let contentView = NSView()
        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView
    }

    private func makeRow(label: String, value: NSTextField) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        value.font = NSFont.systemFont(ofSize: 11)
        value.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [labelField, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    private func populate() {
        nameField.stringValue = fileItem.name
        kindValueField.stringValue = fileItem.kindDescription ?? (
            fileItem.isBrowsable
                ? NSLocalizedString("Folder", comment: "Get Info パネル: 種類（フォルダ）")
                : NSLocalizedString("Document", comment: "Get Info パネル: 種類（不明なファイル）")
        )
        whereValueField.stringValue = fileItem.url.deletingLastPathComponent().path

        if !fileItem.isBrowsable {
            if let size = fileItem.fileSize {
                sizeValueField.stringValue = ByteCountFormatter.getInfo.string(fromByteCount: Int64(size))
            } else {
                sizeValueField.stringValue = "—"
            }
        }

        let keys: Set<URLResourceKey> = [.creationDateKey]
        if let created = (try? fileItem.url.resourceValues(forKeys: keys))?.creationDate {
            createdValueField.stringValue = DateFormatter.getInfo.string(from: created)
        } else {
            createdValueField.stringValue = "—"
        }
        if let modified = fileItem.modificationDate {
            modifiedValueField.stringValue = DateFormatter.getInfo.string(from: modified)
        } else {
            modifiedValueField.stringValue = "—"
        }

        updateSwatchSelection()
    }

    private func updateSwatchSelection() {
        let current = fileItem.labelColor
        for swatch in swatches {
            swatch.isSelectedSwatch = swatch.color == current
        }
    }

    private func applyLabelColor(_ color: LabelColor) {
        do {
            try fileItem.setLabelColor(color)
        } catch {
            NSLog("AquaFinder: setLabelColor failed: \(error)")
        }
        updateSwatchSelection()
    }

    @objc private func toggleGeneralSection() {
        generalContentView.isHidden = disclosureButton.state == .off
    }
}

private extension NSBox {
    static func separatorBox() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

private extension ByteCountFormatter {
    static let getInfo: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private extension DateFormatter {
    static let getInfo: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
