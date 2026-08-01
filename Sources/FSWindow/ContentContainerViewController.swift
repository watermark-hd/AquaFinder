import AppKit

/// Thin container that swaps a single child view controller in and out,
/// used so the split view's content item can stay fixed while Icon/List/
/// Column switch underneath it.
final class ContentContainerViewController: NSViewController {
    private var currentChild: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func setContent(_ child: NSViewController) {
        guard child !== currentChild else { return }

        if let current = currentChild {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        currentChild = child
    }
}
