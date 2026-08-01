import AppKit
import FSCore

/// One clickable color dot in the Get Info label-color row.
final class ColorSwatchView: NSView {
    var color: LabelColor = .none {
        didSet { needsDisplay = true }
    }

    var isSelectedSwatch: Bool = false {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?

    private lazy var clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addGestureRecognizer(clickGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(ovalIn: rect)
        if let nsColor = color.nsColor {
            nsColor.setFill()
            path.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if isSelectedSwatch {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
            NSColor.labelColor.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    @objc private func handleClick() {
        onClick?()
    }
}
