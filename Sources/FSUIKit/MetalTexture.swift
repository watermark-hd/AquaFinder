import AppKit

/// 10.4 Tiger 風のブラッシュドメタル背景。`NSWindow.StyleMask.texturedBackground`
/// は macOS 10.10 以降見た目への効果を失っている（ウィンドウ種別としての
/// 意味は残るが実際に金属調は描画されない）ため、横縞の微妙な明暗ノイズを
/// 持つパターン画像を自前で生成し `NSColor(patternImage:)` として使う。
public enum MetalTexture {
    public static let backgroundColor: NSColor = NSColor(patternImage: makeTextureImage())

    private static func makeTextureImage() -> NSImage {
        let size = NSSize(width: 4, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        for y in 0..<Int(size.height) {
            // 中央付近をわずかに明るくして緩いハイライトを出しつつ、行ごとに
            // 小さなノイズを足すことでブラッシュドメタル特有の細かい横縞を表現する。
            let center = size.height / 2
            let distanceFromCenter = abs(CGFloat(y) - center) / center
            let highlight = (1 - distanceFromCenter) * 0.05
            let noise = CGFloat.random(in: -0.025...0.025)
            let brightness = 0.62 + highlight + noise
            NSColor(calibratedWhite: brightness, alpha: 1.0).setFill()
            NSRect(x: 0, y: CGFloat(y), width: size.width, height: 1).fill()
        }
        image.unlockFocus()
        return image
    }
}
