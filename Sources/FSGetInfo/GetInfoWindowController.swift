import AppKit
import CoreServices
import FSCore
import FSUIKit

/// A single item's Get Info panel: icon/name, the 7 label-color swatches,
/// and the classic Snow Leopard set of collapsible sections — General,
/// More Info, Name & Extension, Open with, and Sharing & Permissions.
/// (Real Finder also has a Preview section; that's the one deliberate
/// scope trim left, since it would duplicate Quick Look.)
public final class GetInfoWindowController: NSWindowController {
    private var fileItem: FileItem
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

    private let moreInfoDisclosureButton = NSButton()
    private let moreInfoContentView = NSStackView()
    private let lastOpenedValueField = NSTextField(labelWithString: "")

    private let nameExtDisclosureButton = NSButton()
    private let nameExtContentView = NSStackView()
    private let nameExtField = NSTextField()
    private let hideExtensionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    private let openWithDisclosureButton = NSButton()
    private let openWithContentView = NSStackView()
    private let openWithPopup = NSPopUpButton()
    private let changeAllButton = NSButton()
    private var openWithAppURLs: [URL] = []

    private let sharingDisclosureButton = NSButton()
    private let sharingContentView = NSStackView()
    private let ownerNameField = NSTextField(labelWithString: "")
    private let ownerPermissionPopup = NSPopUpButton()
    private let groupNameField = NSTextField(labelWithString: "")
    private let groupPermissionPopup = NSPopUpButton()
    private let everyoneLabel = NSTextField(labelWithString: NSLocalizedString("everyone", comment: "Get Info パネル: 共有設定の「その他」行のラベル"))
    private let everyonePermissionPopup = NSPopUpButton()

    private var mainStack: NSStackView!

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
        window?.setContentSize(mainStack.fittingSize)
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

        let generalHeaderRow = makeSectionHeader(
            title: NSLocalizedString("General", comment: "Get Info パネル: 一般セクションの見出し"),
            button: disclosureButton, action: #selector(toggleGeneralSection)
        )
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

        let moreInfoHeaderRow = makeSectionHeader(
            title: NSLocalizedString("More Info", comment: "Get Info パネル: その他の情報セクションの見出し"),
            button: moreInfoDisclosureButton, action: #selector(toggleMoreInfoSection)
        )
        moreInfoContentView.orientation = .vertical
        moreInfoContentView.alignment = .leading
        moreInfoContentView.spacing = 4
        moreInfoContentView.addArrangedSubview(makeRow(
            label: NSLocalizedString("Last opened:", comment: "Get Info パネル: 最終起動日のラベル"), value: lastOpenedValueField
        ))

        let nameExtHeaderRow = makeSectionHeader(
            title: NSLocalizedString("Name & Extension", comment: "Get Info パネル: 名前と拡張子セクションの見出し"),
            button: nameExtDisclosureButton, action: #selector(toggleNameExtSection)
        )
        nameExtField.font = NSFont.systemFont(ofSize: 11)
        nameExtField.isEditable = true
        nameExtField.isBordered = true
        nameExtField.delegate = self
        hideExtensionCheckbox.title = NSLocalizedString("Hide extension", comment: "Get Info パネル: 拡張子を隠すチェックボックス")
        hideExtensionCheckbox.font = NSFont.systemFont(ofSize: 11)
        hideExtensionCheckbox.target = self
        hideExtensionCheckbox.action = #selector(toggleHideExtension)
        nameExtContentView.orientation = .vertical
        nameExtContentView.alignment = .leading
        nameExtContentView.spacing = 6
        nameExtContentView.addArrangedSubview(nameExtField)
        nameExtContentView.addArrangedSubview(hideExtensionCheckbox)
        nameExtField.widthAnchor.constraint(equalTo: nameExtContentView.widthAnchor).isActive = true

        let openWithHeaderRow = makeSectionHeader(
            title: NSLocalizedString("Open with", comment: "Get Info パネル: このアプリケーションで開くセクションの見出し"),
            button: openWithDisclosureButton, action: #selector(toggleOpenWithSection)
        )
        changeAllButton.title = NSLocalizedString("Change All…", comment: "Get Info パネル: すべて変更ボタン")
        changeAllButton.bezelStyle = .rounded
        changeAllButton.font = NSFont.systemFont(ofSize: 11)
        changeAllButton.target = self
        changeAllButton.action = #selector(changeAllApplications)
        openWithContentView.orientation = .vertical
        openWithContentView.alignment = .leading
        openWithContentView.spacing = 6
        openWithContentView.addArrangedSubview(openWithPopup)
        openWithContentView.addArrangedSubview(changeAllButton)
        openWithPopup.widthAnchor.constraint(equalTo: openWithContentView.widthAnchor).isActive = true

        let sharingHeaderRow = makeSectionHeader(
            title: NSLocalizedString("Sharing & Permissions", comment: "Get Info パネル: 共有とアクセス権セクションの見出し"),
            button: sharingDisclosureButton, action: #selector(toggleSharingSection)
        )
        for popup in [ownerPermissionPopup, groupPermissionPopup, everyonePermissionPopup] {
            popup.removeAllItems()
            popup.addItems(withTitles: SimplePermission.allCases.map(\.title))
            popup.target = self
            popup.action = #selector(permissionChanged(_:))
            popup.font = NSFont.systemFont(ofSize: 11)
        }
        ownerPermissionPopup.tag = 0
        groupPermissionPopup.tag = 1
        everyonePermissionPopup.tag = 2
        for field in [ownerNameField, groupNameField, everyoneLabel] {
            field.font = NSFont.systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingMiddle
        }
        let permissionGrid = NSGridView(views: [
            [ownerNameField, ownerPermissionPopup],
            [groupNameField, groupPermissionPopup],
            [everyoneLabel, everyonePermissionPopup],
        ])
        permissionGrid.rowSpacing = 4
        permissionGrid.columnSpacing = 8
        sharingContentView.orientation = .vertical
        sharingContentView.alignment = .leading
        sharingContentView.addArrangedSubview(permissionGrid)

        mainStack = NSStackView(views: [
            headerStack, swatchRow, NSBox.separatorBox(),
            generalHeaderRow, generalContentView, NSBox.separatorBox(),
            moreInfoHeaderRow, moreInfoContentView, NSBox.separatorBox(),
            nameExtHeaderRow, nameExtContentView, NSBox.separatorBox(),
            openWithHeaderRow, openWithContentView, NSBox.separatorBox(),
            sharingHeaderRow, sharingContentView,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        swatchRow.widthAnchor.constraint(lessThanOrEqualTo: mainStack.widthAnchor).isActive = true

        // Plain (non-package) folders don't have a single "opens with"
        // application the way files and app bundles do — matches real
        // Finder omitting this section for ordinary folders.
        if fileItem.isBrowsable, !fileItem.isPackage {
            openWithHeaderRow.isHidden = true
            openWithContentView.isHidden = true
        }

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

    private func makeSectionHeader(title: String, button: NSButton, action: Selector) -> NSStackView {
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .disclosure
        button.title = ""
        button.state = .on
        button.target = self
        button.action = action

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 11)

        let row = NSStackView(views: [button, label])
        row.orientation = .horizontal
        row.spacing = 2
        row.alignment = .centerY
        return row
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
        nameExtField.stringValue = fileItem.name
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

        let keys: Set<URLResourceKey> = [.creationDateKey, .hasHiddenExtensionKey, .contentAccessDateKey]
        let values = try? fileItem.url.resourceValues(forKeys: keys)
        if let created = values?.creationDate {
            createdValueField.stringValue = DateFormatter.getInfo.string(from: created)
        } else {
            createdValueField.stringValue = "—"
        }
        if let modified = fileItem.modificationDate {
            modifiedValueField.stringValue = DateFormatter.getInfo.string(from: modified)
        } else {
            modifiedValueField.stringValue = "—"
        }
        if let accessed = values?.contentAccessDate {
            lastOpenedValueField.stringValue = DateFormatter.getInfo.string(from: accessed)
        } else {
            lastOpenedValueField.stringValue = "—"
        }
        hideExtensionCheckbox.state = (values?.hasHiddenExtension ?? false) ? .on : .off

        updateSwatchSelection()
        populateOpenWith()
        populateSharing()
    }

    private func populateOpenWith() {
        let candidates = (LSCopyApplicationURLsForURL(fileItem.url as CFURL, .all)?.takeRetainedValue() as? [URL]) ?? []
        openWithAppURLs = candidates.sorted { lhs, rhs in
            appDisplayName(for: lhs).localizedStandardCompare(appDisplayName(for: rhs)) == .orderedAscending
        }
        openWithPopup.removeAllItems()
        for appURL in openWithAppURLs {
            let item = NSMenuItem(title: appDisplayName(for: appURL), action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            openWithPopup.menu?.addItem(item)
        }
        if let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: fileItem.url),
           let index = openWithAppURLs.firstIndex(of: defaultURL) {
            openWithPopup.selectItem(at: index)
        }
    }

    private func appDisplayName(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func populateSharing() {
        let (ownerName, groupName, mode) = loadPermissions()
        ownerNameField.stringValue = ownerName
        groupNameField.stringValue = groupName
        ownerPermissionPopup.selectItem(at: SimplePermission.from(bits: (mode >> 6) & 0o7).rawValue)
        groupPermissionPopup.selectItem(at: SimplePermission.from(bits: (mode >> 3) & 0o7).rawValue)
        everyonePermissionPopup.selectItem(at: SimplePermission.from(bits: mode & 0o7).rawValue)
    }

    private func loadPermissions() -> (ownerName: String, groupName: String, mode: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileItem.url.path) else {
            return ("", "", 0)
        }
        let ownerName = attrs[.ownerAccountName] as? String ?? ""
        let groupName = attrs[.groupOwnerAccountName] as? String ?? ""
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return (ownerName, groupName, mode)
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

    @objc private func toggleMoreInfoSection() {
        moreInfoContentView.isHidden = moreInfoDisclosureButton.state == .off
    }

    @objc private func toggleNameExtSection() {
        nameExtContentView.isHidden = nameExtDisclosureButton.state == .off
    }

    @objc private func toggleOpenWithSection() {
        openWithContentView.isHidden = openWithDisclosureButton.state == .off
    }

    @objc private func toggleSharingSection() {
        sharingContentView.isHidden = sharingDisclosureButton.state == .off
    }

    @objc private func toggleHideExtension() {
        var url = fileItem.url
        var values = URLResourceValues()
        values.hasHiddenExtension = hideExtensionCheckbox.state == .on
        try? url.setResourceValues(values)
        iconView.image = IconCache.icon(for: fileItem.url)
    }

    @objc private func changeAllApplications() {
        let index = openWithPopup.indexOfSelectedItem
        guard index >= 0, index < openWithAppURLs.count,
              let typeID = (try? fileItem.url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
              let bundleID = Bundle(url: openWithAppURLs[index])?.bundleIdentifier
        else { return }
        LSSetDefaultRoleHandlerForContentType(typeID as CFString, .all, bundleID as CFString)
    }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard let selected = SimplePermission(rawValue: sender.indexOfSelectedItem) else { return }
        let (_, _, currentMode) = loadPermissions()
        let bits = selected.bits(isDirectory: fileItem.isBrowsable)
        var newMode = currentMode
        switch sender.tag {
        case 0: newMode = (currentMode & ~(0o7 << 6)) | (bits << 6)
        case 1: newMode = (currentMode & ~(0o7 << 3)) | (bits << 3)
        case 2: newMode = (currentMode & ~0o7) | bits
        default: return
        }
        try? FileManager.default.setAttributes([.posixPermissions: newMode], ofItemAtPath: fileItem.url.path)
    }
}

extension GetInfoWindowController: NSTextFieldDelegate {
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, textField === nameExtField else { return }
        let newName = textField.stringValue
        guard newName != fileItem.name else { return }
        guard let destination = try? FileOperations.rename(fileItem.url, to: newName) else {
            textField.stringValue = fileItem.name
            return
        }
        fileItem = FileItem(url: destination)
        window?.title = String(format: NSLocalizedString("%@ Info", comment: "Get Info パネルのタイトル（%@=ファイル名）"), fileItem.name)
        populate()
    }
}

/// Classic Finder's simplified 3-way Sharing & Permissions choices — full
/// POSIX bits and ACL entries exist underneath, but this is what's
/// actually surfaced in the UI, matching how the rest of Get Info already
/// scopes to "what's actually looked at most" rather than every field.
private enum SimplePermission: Int, CaseIterable {
    case readWrite = 0
    case readOnly = 1
    case noAccess = 2

    var title: String {
        switch self {
        case .readWrite: return NSLocalizedString("Read & Write", comment: "Get Info パネル: アクセス権「読み/書き」")
        case .readOnly: return NSLocalizedString("Read Only", comment: "Get Info パネル: アクセス権「読み出しのみ」")
        case .noAccess: return NSLocalizedString("No Access", comment: "Get Info パネル: アクセス権「アクセス不可」")
        }
    }

    func bits(isDirectory: Bool) -> Int {
        switch self {
        case .readWrite: return isDirectory ? 0o7 : 0o6
        case .readOnly: return isDirectory ? 0o5 : 0o4
        case .noAccess: return 0
        }
    }

    static func from(bits: Int) -> SimplePermission {
        switch bits {
        case 0o7, 0o6: return .readWrite
        case 0o5, 0o4: return .readOnly
        default: return .noAccess
        }
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
