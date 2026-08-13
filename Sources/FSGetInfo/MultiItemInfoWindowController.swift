import AppKit
import FSCore
import FSUIKit

/// Get Info for a multi-item selection — real Finder shows a visibly
/// simpler panel here than the single-item one: no Name & Extension, More
/// Info, Open With, or Sharing & Permissions sections (none of them have a
/// sensible multi-item answer), just label color and an aggregate General
/// section (combined Kind/Size, shared parent folder as Where).
public final class MultiItemInfoWindowController: NSWindowController {
    private let fileItems: [FileItem]
    private let sizeCalculators: [FolderSizeCalculator]
    private var calculatedSizes: [URL: Int64] = [:]

    private var swatches: [ColorSwatchView] = []
    private let sizeValueField = NSTextField(labelWithString: "")
    private let whereValueField = NSTextField(labelWithString: "")

    public init(fileItems: [FileItem]) {
        self.fileItems = fileItems
        self.sizeCalculators = fileItems.map { _ in FolderSizeCalculator() }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let titleFormat = NSLocalizedString("%d Items Info", comment: "複数選択のGet Infoパネルのタイトル（%d=件数）")
        panel.title = String(format: titleFormat, fileItems.count)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        buildUI()
        populate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        sizeCalculators.forEach { $0.cancel() }
    }

    private func buildUI() {
        guard let window else { return }

        let countFormat = NSLocalizedString("%d items", comment: "複数選択のGet Infoパネル: 件数見出し（%d=件数）")
        let titleField = NSTextField(labelWithString: String(format: countFormat, fileItems.count))
        titleField.font = NSFont.boldSystemFont(ofSize: 13)
        titleField.alignment = .center

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

        let kindValueField = NSTextField(labelWithString: kindSummary())
        let contentStack = NSStackView(views: [
            makeRow(label: NSLocalizedString("Kind:", comment: "Get Info パネル: 種類のラベル"), value: kindValueField),
            makeRow(label: NSLocalizedString("Size:", comment: "Get Info パネル: サイズのラベル"), value: sizeValueField),
            makeRow(label: NSLocalizedString("Where:", comment: "Get Info パネル: 場所のラベル"), value: whereValueField),
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4

        let mainStack = NSStackView(views: [titleField, swatchRow, NSBox.separatorBox(), contentStack])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
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
        window.setContentSize(mainStack.fittingSize)
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

    private func kindSummary() -> String {
        let folderCount = fileItems.filter(\.isBrowsable).count
        let fileCount = fileItems.count - folderCount
        if folderCount > 0, fileCount > 0 {
            let format = NSLocalizedString(
                "%d folders, %d files", comment: "複数選択Get Info: フォルダとファイルが混在するときの種類（%d %d=件数）"
            )
            return String(format: format, folderCount, fileCount)
        }
        if folderCount > 0 {
            let format = NSLocalizedString("%d folders", comment: "複数選択Get Info: フォルダのみのときの種類（%d=件数）")
            return String(format: format, folderCount)
        }
        let format = NSLocalizedString("%d files", comment: "複数選択Get Info: ファイルのみのときの種類（%d=件数）")
        return String(format: format, fileCount)
    }

    private func populate() {
        whereValueField.stringValue = fileItems.first?.url.deletingLastPathComponent().path ?? ""
        updateSwatchSelection()

        sizeValueField.stringValue = NSLocalizedString("Calculating…", comment: "フォルダサイズ計算中の表示")
        var runningTotal: Int64 = 0
        for item in fileItems where !item.isBrowsable {
            runningTotal += Int64(item.fileSize ?? 0)
        }

        let folders = zip(fileItems, sizeCalculators).filter { $0.0.isBrowsable }
        guard !folders.isEmpty else {
            sizeValueField.stringValue = ByteCountFormatter.multiItemInfo.string(fromByteCount: runningTotal)
            return
        }
        for (item, calculator) in folders {
            calculator.calculate(item.url) { [weak self] bytes in
                guard let self else { return }
                self.calculatedSizes[item.url] = bytes
                let foldersTotal = self.calculatedSizes.values.reduce(0, +)
                self.sizeValueField.stringValue = ByteCountFormatter.multiItemInfo.string(fromByteCount: runningTotal + foldersTotal)
            }
        }
    }

    private func updateSwatchSelection() {
        // Only highlight a color if every selected item shares it — a
        // mixed selection shows no swatch as active, matching real Finder.
        let colors = Set(fileItems.map(\.labelColor))
        let commonColor = colors.count == 1 ? colors.first : nil
        for swatch in swatches {
            swatch.isSelectedSwatch = swatch.color == commonColor
        }
    }

    private func applyLabelColor(_ color: LabelColor) {
        for item in fileItems {
            do {
                try item.setLabelColor(color)
            } catch {
                NSLog("AquaFinder: setLabelColor failed: \(error)")
            }
        }
        updateSwatchSelection()
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
    static let multiItemInfo: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
