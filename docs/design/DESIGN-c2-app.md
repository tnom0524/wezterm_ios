# C-2: iOSアプリ（シミュレータ版）詳細設計（設計: Fable 5 / 実装: Opus）

DESIGN-ios.md「レイヤー構成 > 2. Swift側」の具体化。ゴールは**シミュレータで
bd-annoのペインを表示し、キー入力できるアプリ**。実機・署名・見た目の磨きは対象外。

## 配置

```
<repo-root>/
  wezterm/wezterm-ios-core/     # C-1成果物（Rustコア）
  ios/
    project.yml                 # XcodeGen定義（xcodeprojは生成物、手書きしない）
    build-rust.sh               # Rust→xcframework
    WeztermMobile/              # Swiftソース
      WeztermMobileApp.swift
      ConnectionStore.swift     # ClientDelegate実装。コールバックはMainActorへhop
      ConnectView.swift         # アドレス入力（既定 100.64.0.1:17777）→接続
      PaneListView.swift        # list_panes結果。タップでattach
      TerminalView.swift        # Snapshot→AttributedString、等幅フォント
      KeyInputView.swift        # 非表示UITextField(UIKeyInput)＋アクセサリバー
      Generated/                # uniffi-bindgen生成Swift（build-rust.shが更新）
```

## ビルドパイプライン

1. `build-rust.sh`:
   - `cargo build -p wezterm-ios-core --release --target aarch64-apple-ios-sim`
     （実機targetは今回ビルドしない。xcframeworkはsimスライスのみでよい）
   - `uniffi-bindgen`でSwift生成 → `ios/WeztermMobile/Generated/`
   - `xcodebuild -create-xcframework -library ... -headers ...` → `ios/WeztermIOSCore.xcframework`
   - modulemap/ヘッダはuniffi生成物を使用
2. XcodeGen（`brew install xcodegen`）で `project.yml` → `.xcodeproj` 生成
   - target: iOSアプリ、bundle id `com.example.weztermmobile`、iOS 17+、署名不要設定
     （シミュレータはCODE_SIGNING_ALLOWED=NOでビルド可）
   - xcframeworkをリンク
3. `xcodebuild -project ... -scheme WeztermMobile -destination 'platform=iOS Simulator,name=<devicename>' build`

## UI仕様（最小）

- ConnectView: TextField(addr) + Connectボタン。接続失敗はアラート表示
- PaneListView: `pane_id / title / active / size` を行表示。タップ→TerminalView
- TerminalView:
  - Snapshot.rows → AttributedString（SpanのfgをUIColor(rgba)に、reverseはfg/bg入替、
    bold/italic/underlineはフォント属性）。`Text` + `.font(.system(.body, design: .monospaced))`
  - カーソル: cursor_row/colの文字をreverse表示で代用
  - attach時のcols/rows: v1は接続先ペインの現サイズをそのまま使う（resizeは実装するが
    自動追従はv2。画面回転等は無視）
  - 下部に入力バー: [Esc][Tab][Ctrl][↑][↓][←][→][Ctrl-C] ボタン＋テキスト入力
    - Ctrlはトグル: ON中に打った次の1文字を ^X (byte & 0x1f) にして送る
    - 通常文字はUTF-8バイトでsend_input。改行は \r
- 切断時（on_disconnected）: バナー表示＋再接続ボタン

## シミュレータでの検証（エージェントが自動で行う）

1. `xcrun simctl list devices` で利用可能デバイス確認（無ければ `simctl create`）
2. boot → `xcodebuild ... build` → `simctl install` → `simctl launch`
3. 検証はスクリーンショットベース: `xcrun simctl io booted screenshot /tmp/shot.png`
   - 起動直後（ConnectView）、接続後（PaneList）、attach後（Terminal画面に
     bd-annoのペイン内容が見えている）の3枚を撮って目視確認レベルの妥当性を確認
   - シミュレータはMacのネットワークを共有するため 100.64.0.1:17777 にそのまま届く
4. 入力の自動検証は不要（selftest/smokeで担保済み）。ただしlaunch後にクラッシュして
   いないこと（`simctl spawn booted log` かプロセス生存で確認）

## 注意

- ユーザーの本物のペイン（bd-annoのpane 4/5）への**書き込みはしない**。表示は可
- Xcode 26 beta / iOS 26 SDK。xcode-select設定済み。シミュレータランタイムは
  ダウンロード中の可能性 → `simctl list runtimes` で確認、無ければ待つか報告
- uniffiのSwift並行性: コールバックは非メインスレッド。必ずTask { @MainActor in ... } でhop
- AttributedStringの構築が重い場合もv1では気にしない（最適化はv2）
