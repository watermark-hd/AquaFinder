import AppKit
import FSCore

/// Tracks Option/⌘ modifier state sampled continuously during a drag —
/// `validateDrop`/its NSCollectionView equivalent fires repeatedly as the
/// mouse moves over a drop target, so this is called from there — rather
/// than reading `NSEvent.modifierFlags` fresh only once at drop time.
///
/// Two earlier attempts at this (a plain one-shot `NSEvent.modifierFlags`
/// read inside acceptDrop, then trusting
/// `NSDraggingInfo.draggingSourceOperationMask`) both failed to make
/// Option-drag reliably resolve to a copy in this app's drag setup, so
/// this sample-during-hover approach is the fallback: it avoids any
/// question of exactly what state either of those report at the single
/// instant the drop is accepted.
public final class DragModifierTracker {
    private var optionHeld = false
    private var commandHeld = false

    public init() {}

    public func sample() {
        optionHeld = NSEvent.modifierFlags.contains(.option)
        commandHeld = NSEvent.modifierFlags.contains(.command)
    }

    public func resolve(source: URL, destinationDirectory: URL) -> DragOperationKind {
        FileOperations.resolveDragOperation(
            source: source,
            destinationDirectory: destinationDirectory,
            optionHeld: optionHeld,
            commandHeld: commandHeld
        )
    }
}
