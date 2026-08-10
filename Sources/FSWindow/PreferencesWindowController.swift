import AppKit
import FSUIKit

/// テーマ（10.4 メタル調 / 10.6 グラファイト）と文字サイズを切り替える
/// 環境設定パネル。GetInfoWindowController と同じ軽量な NSPanel スタイル。
/// 変更は AppearancePreferenceStore が即座に永続化＋通知するので、この
/// パネル自身は選択状態を保持するだけで、実際の反映は各 MainWindowController
/// が通知を受けて行う。
public final class PreferencesWindowController: NSWindowController {
    private let themeControl = NSSegmentedControl(
        labels: AppTheme.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil
    )
    private let textSizeControl = NSSegmentedControl(
        labels: TextSize.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil
    )

    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 190),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = NSLocalizedString("Preferences", comment: "環境設定パネルのタイトル")
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let window, let contentView = window.contentView else { return }

        themeControl.segmentStyle = .rounded
        themeControl.target = self
        themeControl.action = #selector(themeChanged)
        if let index = AppTheme.allCases.firstIndex(of: AppearancePreferenceStore.theme) {
            themeControl.setSelected(true, forSegment: index)
        }

        textSizeControl.segmentStyle = .rounded
        textSizeControl.target = self
        textSizeControl.action = #selector(textSizeChanged)
        if let index = TextSize.allCases.firstIndex(of: AppearancePreferenceStore.textSize) {
            textSizeControl.setSelected(true, forSegment: index)
        }

        let themeLabel = NSTextField(labelWithString: NSLocalizedString("Theme:", comment: "環境設定: テーマのラベル"))
        themeLabel.alignment = .right
        themeLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let textSizeLabel = NSTextField(labelWithString: NSLocalizedString("Text Size:", comment: "環境設定: 文字サイズのラベル"))
        textSizeLabel.alignment = .right
        textSizeLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let themeRow = NSStackView(views: [themeLabel, themeControl])
        themeRow.orientation = .horizontal
        themeRow.spacing = 8

        let textSizeRow = NSStackView(views: [textSizeLabel, textSizeControl])
        textSizeRow.orientation = .horizontal
        textSizeRow.spacing = 8

        let resetLayoutButton = NSButton(
            title: NSLocalizedString("Reset Window Size to Default", comment: "環境設定: ウィンドウサイズ/サイドバー幅を既定値に戻すボタン"),
            target: self, action: #selector(resetWindowLayout)
        )
        resetLayoutButton.bezelStyle = .rounded

        let stack = NSStackView(views: [themeRow, textSizeRow, resetLayoutButton])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
        ])
    }

    @objc private func themeChanged() {
        let index = themeControl.selectedSegment
        guard AppTheme.allCases.indices.contains(index) else { return }
        AppearancePreferenceStore.theme = AppTheme.allCases[index]
    }

    @objc private func textSizeChanged() {
        let index = textSizeControl.selectedSegment
        guard TextSize.allCases.indices.contains(index) else { return }
        AppearancePreferenceStore.textSize = TextSize.allCases[index]
    }

    @objc private func resetWindowLayout() {
        NotificationCenter.default.post(name: .resetWindowLayoutRequested, object: nil)
    }
}
