import AppKit
import FSCore

/// 開いている Get Info パネルを URL ごとにアプリ全体で一元管理する。
/// 複数ウィンドウ対応前は MainWindowController が自分専用の辞書を持って
/// いたが、それだと同じファイルの Get Info が別ウィンドウからだと別々に
/// 開いてしまう（実 Finder は常に1つ）。共有シングルトンに寄せることで
/// どのウィンドウから開いても既存パネルにフォーカスするようにする。
public final class GetInfoWindowRegistry {
    public static let shared = GetInfoWindowRegistry()

    private var windows: [URL: GetInfoWindowController] = [:]

    private init() {}

    public func show(for fileItem: FileItem) {
        if let existing = windows[fileItem.url] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = GetInfoWindowController(fileItem: fileItem)
        windows[fileItem.url] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self] _ in
            self?.windows.removeValue(forKey: fileItem.url)
        }
        controller.showWindow(nil)
    }
}
