import AppKit

/// Paints the sidebar's background as a smooth vertical gradient — the
/// stock `.sourceList` vibrancy material renders flat white under this
/// app's forced Aqua appearance (same failure mode already worked around
/// for the status bar and icon/list scroll views), and real Snow
/// Leopard's source list wasn't flat white either. A plain view (not a
/// tiled pattern image like MetalTexture) so the gradient always spans
/// the sidebar's actual height with no banding.
///
/// Deliberately the *same* regardless of theme — a Brushed Metal-matched
/// dark gray made the sidebar feel too heavy on its own; this lighter,
/// faintly blue-tinted gradient (Graphite's look) reads better against
/// both window chrome styles.
public final class SidebarBackgroundView: NSView {
    private let topColor = NSColor(calibratedRed: 0.867, green: 0.894, blue: 0.918, alpha: 1.0)
    private let bottomColor = NSColor(calibratedRed: 0.792, green: 0.824, blue: 0.855, alpha: 1.0)

    public func applyTheme(_ theme: AppTheme) {
        // No-op: kept so callers (MainWindowController) don't need a
        // special case, but the sidebar no longer varies by theme.
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: topColor, ending: bottomColor)?.draw(in: bounds, angle: 90)
    }
}
