import Foundation
import FSCore

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

    /// `currentDirectoryURL`'s children in the exact order this view is
    /// currently displaying them — each conformer has its own independent
    /// sort state (List view's clickable column headers, Icon/Column
    /// view's shared "Arrange By" field), so Quick Look's prev/next
    /// stepping reads this instead of re-deriving a possibly-different
    /// order from a shared cache.
    var currentSortedItems: [FileItem] { get }

    func refresh()

    /// Starts inline rename of the current selection.
    func beginRename()

    /// Selects (and scrolls to) the item at this URL, if it's reachable
    /// from this view — used to keep the browser's selection highlight in
    /// sync while stepping through Quick Look with arrow keys.
    func selectItem(at url: URL)
}
