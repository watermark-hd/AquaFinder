import Foundation

/// A lightweight, value-type wrapper around a file URL. Resource values
/// (name, directory-ness, package-ness) are looked up lazily rather than
/// cached at init time, since the underlying file can change while an item
/// is held (e.g. across a DirectoryWatcher refresh).
public struct FileItem: Identifiable, Hashable {
    public let url: URL

    public var id: URL { url }

    public init(url: URL) {
        self.url = url
    }

    public var name: String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
    }

    public var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    public var isPackage: Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    /// A folder you can descend into. Packages/bundles (.app, etc.) are
    /// directories on disk but behave as opaque leaf files in Finder.
    public var isBrowsable: Bool {
        isDirectory && !isPackage
    }

    /// Byte size for regular files. Deliberately not computed recursively
    /// for folders here (that's the async, cancellable job Get Info does
    /// in Phase 3) — list view shows "--" for folders instead.
    public var fileSize: Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    public var modificationDate: Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Finder's "Kind" column string (e.g. "Folder", "PDF Document").
    public var kindDescription: String? {
        (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription
    }
}
