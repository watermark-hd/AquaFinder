import Foundation

/// Shared surface the three browsing view controllers (Column/List/Icon)
/// expose so MainWindowController's File-menu commands (New Folder,
/// Duplicate, Move to Trash, Rename) can act on "whichever view is
/// currently active" without needing to know which concrete type it is.
public protocol SelectionProviding: AnyObject {
    var selectedURLs: [URL] { get }

    /// Directory new items (New Folder, drop targets, etc.) should be
    /// created in — see each conformer's own doc comment for how it's
    /// derived from the current selection/root.
    var currentDirectoryURL: URL { get }

    func refresh()

    /// Starts inline rename of the current selection.
    func beginRename()

    /// Selects (and scrolls to) the item at this URL, if it's reachable
    /// from this view — used to keep the browser's selection highlight in
    /// sync while stepping through Quick Look with arrow keys.
    func selectItem(at url: URL)
}
