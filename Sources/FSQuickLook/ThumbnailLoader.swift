import AppKit
import Quartz
import QuickLookThumbnailing

/// Real content thumbnails (image contents, PDF first page, etc.) for
/// Icon View, upgrading past the generic per-UTI icons `IconCache` gives
/// out. Loading is asynchronous — callers should already be showing the
/// generic icon as a placeholder and swap it out when `completion` fires.
public enum ThumbnailLoader {
    private static var cache: [URL: NSImage] = [:]

    public static func thumbnail(for url: URL, size: CGSize, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            guard let representation, error == nil else { return }
            let image = NSImage(cgImage: representation.cgImage, size: size)
            DispatchQueue.main.async {
                cache[url] = image
                completion(image)
            }
        }
    }
}
