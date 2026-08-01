import AppKit

/// Bottom status bar: "N items, X GB available" — matches what real
/// Finder shows, using the same `.volumeAvailableCapacityForImportantUsage`
/// figure it does (accounts for purgeable/APFS space) rather than the
/// older, less accurate `.volumeAvailableCapacity`.
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(itemCount: Int, directoryURL: URL) {
        var text = "\(itemCount) item\(itemCount == 1 ? "" : "s")"
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if let capacity = (try? directoryURL.resourceValues(forKeys: keys))?.volumeAvailableCapacityForImportantUsage {
            text += ", \(ByteCountFormatter.statusBar.string(fromByteCount: capacity)) available"
        }
        label.stringValue = text
    }
}

private extension ByteCountFormatter {
    static let statusBar: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
