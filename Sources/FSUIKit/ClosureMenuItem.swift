import AppKit

/// NSMenuItem requires an @objc target-action pair; this wraps a Swift
/// closure so context menus can be built inline without hand-rolling a
/// target object for every item.
public final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
