# iPad 版 実装計画（マスタープラン）

WezTerm Mobile を iPhone 専用アプリからユニバーサルアプリ化し、iPad で
「ハードウェアキーボード + 大画面サイドバー」の快適なターミナル体験を実現する。

この `docs/ipad/` 配下は **フェーズごとに自己完結した実装仕様書** になっている。
各フェーズは 1 つの実装エージェント（または 1 セッション）にそのままスペックとして
渡せる粒度で書かれている。

## フェーズ一覧と依存関係

| # | ドキュメント | 内容 | 依存 | 実装量目安 |
|---|---|---|---|---|
| 0 | [00-universal.md](00-universal.md) | ユニバーサル化（device family / orientation / ビルド確認） | なし | 極小（設定のみ） |
| 1 | [01-hardware-keyboard.md](01-hardware-keyboard.md) | ハードウェアキーボード対応（矢印 / Esc / Ctrl / Cmd ショートカット） | 0 | 中 |
| 2 | [02-split-layout.md](02-split-layout.md) | NavigationSplitView レイアウト（サイドバー + ターミナル） | 0 | 中 |
| 3 | [03-polish.md](03-polish.md) | フォントサイズ可変・トラックパッドホイール転送 | 0〜2 | 中 |

- 1 と 2 は互いに独立（並行実装可）。3 は 0 のみ必須依存だが、2 の後に
  やるほうが手戻りがない（レイアウト確定後にジェスチャを載せるため）。
- **推奨順: 0 → 1 → 2 → 3**。1 を先にするのは、ハードウェアキーボードが
  iPad 体験の価値の大半を占め、かつ技術リスク（キー配送経路）が最も高いため。
  リスクの高いものから潰す。

## ゴール / ノンゴール

### ゴール（v1）
- iPad（実機・シミュレータ）で iPhone 版と同等機能がすべて動く
- Magic Keyboard / Bluetooth キーボードで矢印・Esc・Ctrl 組み合わせ・
  Cmd+V(ペースト)・Cmd+C(コピーシート) が使える
- サイドバー（接続先 + ペイン一覧）とターミナルの 2 カラムレイアウト
- Split View / Stage Manager でのリサイズに追従（既存の GeometryReader +
  デバウンスリサイズがそのまま効くはず — 検証項目）
- フォントサイズ調整（ピンチ + 永続化）。iPad の物理サイズでは 14pt 固定は小さすぎる

### ノンゴール（v1 では意図的にやらない）
- **マルチウィンドウ / マルチシーン**: ConnectionStore を Scene ごとに分離する
  設計・テストコストが高い。需要が確認できてから
- **Option-as-Meta 設定**: Option キーは UITextInput 経由で特殊文字入力として
  流す（Mac のデフォルトと同じ）。Meta 化は設定項目ごと将来検討
- **画面内ペイン分割（1 画面に複数ターミナル）**: mux プロトコル上は可能だが
  レンダラ・リサイズ調停が別物になる
- **外部ディスプレイ / Apple Pencil 対応**

## 現状アーキテクチャの要点（実装者向け 30 秒サマリ）

全体は `docs/ARCHITECTURE.md` 参照。iPad 化に関係する事実だけ:

- UI は SwiftUI（iOS 18 API 使用: `onScrollGeometryChange` / `onScrollPhaseChange`）。
  画面フロー: `ConnectView` → `PaneListView` → `TerminalView`（NavigationStack）
- Rust コア (`wezterm-ios-core`) は **iPad 対応で一切変更不要**。
  エンジンは `panes: HashMap<PaneId, PaneState>` で複数ペインの状態を保持し、
  `attach` はペイン単位で `GetPaneRenderChanges` 購読を張る（lib.rs:508 `do_attach`）。
  複数回 attach しても古いペインの購読は生きたままだが、Swift 側
  `handleSnapshot` が `attachedPaneId` でフィルタするので実害なし（帯域のみ）
- ターミナル描画は `TerminalView.swift` の AttributedString 直組み。フォント
  メトリクス（14pt 固定）は同ファイルの file-private 定数
- キー入力は `KeyInputView.swift` の `TerminalKeyView`（UIView + UITextInput、
  fake document 方式）。**この IME 機構は実績があり壊れやすい。既存メソッドの
  変更は禁止、追加のみ可**（詳細は下記の不可侵ルール）
- 描画スロットル / スクロール凍結 / 履歴プリフェッチは `ConnectionStore.swift`。
  iPad 化で触るのはペイン切替リセット（02 参照）のみ

## 全フェーズ共通の運用ルール

1. **作業分担**: 設計判断・レビュー・ビルド/インストール・git 操作は本体
   （設計エージェント）が行う。実装エージェント（サブエージェント）は
   Swift/設定ファイルの編集のみ。**実装エージェントは git コマンドを実行しない**
2. **`ios/project.yml` の変更は実装エージェント禁止**（本体が直接編集する）。
   理由: ワーキングツリーに個人設定 `bundleIdPrefix: dev.nyaga` の未コミット差分が
   常駐している。コミット時は `git add -p` で該当ハンクを除外し、公開ツリーは
   `com.example` を維持すること。**project.yml を丸ごと `git add` してはならない**
3. **IME 機構の不可侵**: `TerminalKeyView` の UITextInput プロトコル実装
   （`insertText` / `setMarkedText` / `unmarkText` / position・range 系 / notify 系）
   と fake document 状態管理は一切変更しない。ハードウェアキーボード対応（01）は
   `pressesBegan` / `keyCommands` の **追加** と新規コールバックの追加のみで実現する
4. **iPhone の挙動を変えない**: iPhone では従来の画面フロー・入力 UX を
   ビット単位で維持する。分岐は idiom（`UIDevice.current.userInterfaceIdiom == .pad`）
   で行い、サイズクラスでは行わない（iPad の Slide Over で compact になっても
   iPad 用 UI のまま崩れず動くべきで、iPhone UI に切り替わるべきではない）
5. **各フェーズの完了条件**: 各ドキュメント末尾の受け入れチェックリストを
   シミュレータ（+ 可能なら実機）で全通し。ユーザー確認が取れるまで次フェーズの
   コミットに混ぜない（フェーズ = コミット単位）

## ビルド・実行コマンド（共通リファレンス）

```bash
# .xcodeproj 再生成（project.yml 変更時のみ必要）
cd /Users/nyaga/work/05-wezterm_ios/ios && xcodegen generate

# iPad シミュレータビルド（Debug / 署名不要）
xcodebuild -project /Users/nyaga/work/05-wezterm_ios/ios/WeztermMobile.xcodeproj \
  -scheme WeztermMobile -configuration Debug \
  -destination 'id=235CE990-DE93-4D43-B8F3-5300AA704256' \
  -derivedDataPath /Users/nyaga/work/05-wezterm_ios/ios/build build

# インストール & 起動（--autoconnect --autoattach で最初の接続先/ペインへ直行）
xcrun simctl boot 235CE990-DE93-4D43-B8F3-5300AA704256   # 起動済みならエラー、無視可
xcrun simctl install 235CE990-DE93-4D43-B8F3-5300AA704256 \
  /Users/nyaga/work/05-wezterm_ios/ios/build/Build/Products/Debug-iphonesimulator/WeztermMobile.app
xcrun simctl launch 235CE990-DE93-4D43-B8F3-5300AA704256 <bundle-id> --autoconnect --autoattach
```

- 利用可能な iPad シミュレータ（この Mac、2026-07 時点）:
  - iPad Pro 11-inch (M4): `235CE990-DE93-4D43-B8F3-5300AA704256` ← 標準はこれ
  - iPad Pro 13-inch (M4): `9A87343A-FBFE-424E-A384-DCB51E15F069`
  - iPad mini (A17 Pro): `A8FF0CF1-666A-4587-A822-DA46855B734F`
- 既知の罠: `-destination name=booted` はこの Xcode beta で失敗する。UUID 指定必須
- 既知の罠: **シミュレータは Mac の Tailscale IP で出る**ため、接続先ポートは
  Mac 用の 17777 を使う（17778 は iPhone/iPad 実機 IP 専用の socat range 制限）
- 新しいシミュレータに接続先を注入する手順: `simctl spawn defaults write` は
  アプリコンテナと別ドメインに書かれて**効かない**。シミュレータを shutdown した
  状態でアプリコンテナの plist を直接編集する:
  `plutil -replace savedConnections -data "$(printf '%s' '<JSON>' | base64)" \
   $(xcrun simctl get_app_container <UDID> <bundle-id> data)/Library/Preferences/<bundle-id>.plist`
- 既知の罠: マルチアーキテクチャのシミュレータビルドはリンクで失敗する
  （libwezterm_ios_core.a が arm64 のみ）。arm64 シミュレータなら問題ない
- 実機: iPhone と同じくペアリング済みなら `devicectl` で無線インストール可
- ハードウェアキーボードのシミュレート: Simulator メニュー
  I/O > Keyboard > "Send Keyboard Input to Device" を ON にして Mac のキーボードで
  打鍵。**Ctrl/Cmd 修飾も転送される**。最終確認は実機 + 実キーボード推奨

## リスク台帳

| リスク | 影響 | 対策 |
|---|---|---|
| 矢印キーが UITextInput のシステム処理に食われて `pressesBegan` に届かない | 01 の根幹 | 01 冒頭の「スパイク」を最初に実施し、`keyCommands`(+`wantsPriorityOverSystemBehavior`) と `pressesBegan` のどちらで届くか実測で決める |
| IME 変換中に矢印/Space/Return を横取りして変換操作を壊す | 日本語入力全滅 | `markedText != nil` の間はキー横取りを全面停止（01 に明記） |
| キーリピート（矢印長押し）が発火しない | vim/less で致命的 | 実測 → 発火しなければ pressesBegan/pressesEnded で自前リピートタイマ（01 にフォールバック設計あり） |
| ペイン切替で rowCache の StableRowIndex がペイン間衝突 | 履歴表示が化ける | `switchPane` でペイン固有状態を全リセット（02 に実装仕様） |
| project.yml の個人差分を誤コミット | 公開リポジトリに個人 ID 露出 | 運用ルール 2。コミットは本体のみが実施 |
| 14pt 固定フォントが 13" iPad で小さすぎる | 使い物にならない | 03 でフォントサイズ可変化。それまでは既知の制限として許容 |
| Split View / Stage Manager のリサイズ追従漏れ | 表示崩れ | 既存 GeometryReader + 0.5s デバウンスで理論上は追従する。00 の受け入れ項目で検証 |

## この計画書群の更新ルール

実装中に計画と実態がズレたら、**コードではなくこのドキュメントを直してから**
実装を続ける（次のフェーズのエージェントが古い仕様を読むのを防ぐ）。
