# フェーズ 0: ユニバーサル化

iPad をビルドターゲットに加え、**コード変更ゼロで** iPhone 版と同じ UI が
iPad 上で動くことを確認する。ここでの成果物は設定変更 2 ファイルと動作確認のみ。

## 変更 1: `ios/project.yml`（⚠ 本体エージェントのみが編集）

ターゲットの `settings.base` に device family を追加する:

```yaml
targets:
  WeztermMobile:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ...   # 既存
        TARGETED_DEVICE_FAMILY: "1,2"    # ← 追加（1=iPhone, 2=iPad）
```

変更後に `cd ios && xcodegen generate` を忘れないこと。

**コミット時の注意**: ワーキングツリーの project.yml には個人設定
`bundleIdPrefix: dev.nyaga` の未コミット差分がある。`git add -p` で
`TARGETED_DEVICE_FAMILY` のハンクだけをステージし、bundleIdPrefix /
PRODUCT_BUNDLE_IDENTIFIER のハンクは除外する。

## 変更 2: `ios/WeztermMobile/Info.plist`

iPad 用の orientation キーを追加する。**4 方向すべて**をサポートすること
（`UIRequiresFullScreen` を立てずに Split View / Stage Manager 対応にするには
4 方向サポートが必須。全画面固定アプリは iPadOS でマルチタスク非対応の烙印を押される）:

```xml
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

既存の `UISupportedInterfaceOrientations`（iPhone 用 3 方向）はそのまま残す。
`UILaunchScreen`（空 dict）は既にあるので追加不要。`LSRequiresIPhoneOS` も
ユニバーサルアプリで問題ないためそのまま。

## 変更なしで動くはずのもの（確認のみ）

- SwiftUI レイアウトはすべて相対サイズなので iPad の画面いっぱいに広がる
- `TerminalView` の `GeometryReader` + `scheduleResize`（0.5s デバウンス）が
  iPad の広いグリッド（例: 横向き 13" で 200 cols 超）を自動計算して resize PDU を送る
- Rust コア / XCFramework は再ビルド不要（アーキテクチャは同じ arm64）

## ビルド・確認手順

PLAN.md の共通コマンド参照。iPad Pro 11-inch (M4) シミュレータ
（`235CE990-DE93-4D43-B8F3-5300AA704256`）でビルド → インストール → 起動。

## 受け入れチェックリスト

- [ ] iPad シミュレータでビルド・起動できる（Debug、署名なし）
- [ ] iPhone シミュレータでも従来どおりビルド・起動できる（回帰確認）
- [ ] 接続 → ペイン一覧 → ターミナル表示まで一通り動く
- [ ] ターミナルのグリッドが iPad の画面サイズに応じて拡大している
      （サーバ側 `wezterm cli list` で cols/rows が反映されているのが確実）
- [ ] 回転（縦↔横）でリサイズが追従する
- [ ] Split View（Safari と 50/50 など）でリサイズが追従する
- [ ] ソフトキーボード表示/非表示でターミナル領域が正しく伸縮する
- [ ] 日本語 IME 入力（変換ストリップ表示含む）が iPad でも動く

## 既知の許容事項（このフェーズでは直さない）

- 14pt フォントは iPad では小さい → フェーズ 3
- 画面フローが iPhone 流のプッシュ遷移のまま → フェーズ 2
- ハードウェアキーボードの矢印・Ctrl が効かない → フェーズ 1
