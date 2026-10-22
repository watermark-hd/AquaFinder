import AppKit

/// A determinate progress bar drawn in the classic glossy-blue Aqua style
/// (Tiger/early Leopard's Finder copy dialogs, Installer.app, etc.) —
/// NSProgressIndicator's own `.bar` style has looked like a flat, thin
/// modern line since well before this app's era, with no supported way to
/// bring back the glossy look, so this draws it by hand instead.
public final class ClassicAquaProgressBar: NSView {
    /// 0...1. KVO-driven callers (observing a real `Progress`) just set
    /// this on the main thread; `needsDisplay` takes care of the redraw.
    public var fractionCompleted: Double = 0 {
        didSet {
            guard fractionCompleted != oldValue else { return }
            needsDisplay = true
        }
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        let trackRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = trackRect.height / 2
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)

        // Recessed track — a light gray well with a subtle dark top edge,
        // the same "something is carved into the surface" look the rest of
        // the app's classic chrome uses elsewhere (see ClassicSegmentedControl).
        NSColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1.0).setFill()
        trackPath.fill()
        NSColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1.0).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        let clampedFraction = max(0, min(1, fractionCompleted))
        guard clampedFraction > 0 else { return }

        let fillWidth = max(trackRect.height, trackRect.width * CGFloat(clampedFraction))
        let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)

        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()

        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        fillPath.addClip()

        // Classic Aqua blue glass: a mid-to-deep blue base gradient, with a
        // brighter glossy highlight band across the top third to read as a
        // rounded, reflective pill rather than a flat fill.
        // A user who'd been running real Tiger/Panther-era Aqua compared
        // this against the sidebar's own selection-highlight blue and
        // found the original version of this too dark/navy by comparison
        // — these stops are shifted lighter and more saturated to read
        // closer to that reference blue.
        let baseGradient = NSGradient(colors: [
            NSColor(srgbRed: 0.50, green: 0.72, blue: 1.00, alpha: 1.0),
            NSColor(srgbRed: 0.25, green: 0.55, blue: 0.98, alpha: 1.0),
            NSColor(srgbRed: 0.15, green: 0.42, blue: 0.90, alpha: 1.0),
        ])
        baseGradient?.draw(in: fillRect, angle: 90)

        let highlightRect = NSRect(
            x: fillRect.minX, y: fillRect.minY,
            width: fillRect.width, height: fillRect.height * 0.5
        )
        let highlightGradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.55),
            NSColor.white.withAlphaComponent(0.05),
        ])
        highlightGradient?.draw(in: highlightRect, angle: 90)

        NSGraphicsContext.restoreGraphicsState()
    }
}
