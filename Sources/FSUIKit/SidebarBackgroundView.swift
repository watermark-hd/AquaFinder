import AppKit

/// Paints the sidebar's background as a smooth vertical gradient matching
/// whichever theme is active — the stock `.sourceList` vibrancy material
/// renders flat white under this app's forced Aqua appearance (same
/// failure mode already worked around for the status bar and icon/list
/// scroll views), and real Snow Leopard's source list wasn't flat white
/// either. A plain view (not a tiled pattern image like MetalTexture) so
/// the gradient always spans the sidebar's actual height with no banding.
public final class SidebarBackgroundView: NSView {
    private var topColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)
    private var bottomColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyTheme(.graphite10_6)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func applyTheme(_ theme: AppTheme) {
        switch theme {
        case .graphite10_6:
            topColor = NSColor(calibratedRed: 0.867, green: 0.894, blue: 0.918, alpha: 1.0)
            bottomColor = NSColor(calibratedRed: 0.792, green: 0.824, blue: 0.855, alpha: 1.0)
        case .metal10_4:
            topColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)
            bottomColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: topColor, ending: bottomColor)?.draw(in: bounds, angle: 90)
    }
}
