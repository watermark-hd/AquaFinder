import AppKit
import FSCore

extension LabelColor {
    public var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .gray: return .systemGray
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }
}

public enum LabelSwatchImage {
    /// Renders a small filled circle for a label color (an open ring for
    /// `.none`), used as the icon on Color Label menu items and swatch
    /// buttons.
    public static func make(for color: LabelColor, diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        let rect = NSRect(x: 0.5, y: 0.5, width: diameter - 1, height: diameter - 1)
        let path = NSBezierPath(ovalIn: rect)
        if let nsColor = color.nsColor {
            nsColor.setFill()
            path.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        image.unlockFocus()
        return image
    }
}
