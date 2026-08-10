# AquaFinder

Mac OS X 10.4〜10.6（Tiger〜Snow Leopard）時代のFinderの雰囲気を再現した、個人開発のファイラーアプリです。Apple社およびFinderとは無関係の非公式・非商用のプロジェクトです。

## 主な機能

- アイコン表示・リスト表示・カラム表示
- 複数ウィンドウ対応、ファイルのコピー＆ペースト（⌘C / ⌘V）
- リスト表示でフォルダのサイズを自動計算して表示
- テーマ切り替え：10.6風グラファイト／10.4風ブラッシュドメタル
- 文字サイズ・行の高さの調整（環境設定）
- 日本語・英語ローカライズ対応
- ラベルカラー、Get Info、Quick Look など classic Finder の主要機能

## 動作環境

- **macOS 10.15 (Catalina) 以降**
- Apple Silicon（M1以降）・Intel Mac の両方に対応（Universal Binary）

## インストール方法

1. [Releases](../../releases) から最新の `AquaFinder.dmg` をダウンロード
2. DMGを開き、`AquaFinder.app` を `Applications` フォルダにドラッグ
3. 初回起動時、Appleに登録された開発者による署名ではないため「開発元が未確認のため開けません」という警告が出ます。その場合は次のいずれかで開いてください：
   - `AquaFinder.app` を **右クリック（またはControl+クリック）→「開く」** を選択し、表示されるダイアログで「開く」を選ぶ
   - もしくは、システム設定 →「プライバシーとセキュリティ」を開き、AquaFinderに関するメッセージの横にある「このまま開く」をクリック
   - 一度許可すれば、以降は通常通り起動できます

## ソースからビルドする場合

Swift 5.9以降のツールチェーンが必要です（Xcode Command Line Tools でも可）。

```sh
git clone https://github.com/<your-username>/AquaFinder.git
cd AquaFinder
./Scripts/build-universal.sh   # ユニバーサルバイナリをビルド
./Scripts/make-app-bundle.sh   # AquaFinder.app を組み立て
open AquaFinder.app
```

## ライセンス

[MIT License](LICENSE)
