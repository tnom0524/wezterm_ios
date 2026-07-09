# WezTerm Mobile

[WezTerm](https://wezfurlong.org/wezterm/) マルチプレクサのネイティブiOSシンクライアントです。
リモートマシンで動く `wezterm-mux-server` のセッションにiPhoneからアタッチします —
tmux不要、mosh不要、アプリ内SSHスタックも不要。ローミング（Wi-Fi ⇄ LTE）は下層の
[Tailscale](https://tailscale.com/)/WireGuardが吸収するため、回線が切り替わっても
セッションは切れません。

English: [README.md](README.md)

```
iPhone (SwiftUI)                            サーバー (EC2等)
┌───────────────────────────┐               ┌─────────────────────────┐
│ ターミナルUI / IME / キー   │               │ wezterm-mux-server      │
│   ↕ UniFFI                │  Tailscale    │   ↕ unixソケット         │
│ Rustコア                   │═══════════════│ socat  TCP:17778        │
│  (wezterm codec + TCP)    │  (WireGuardが │  (tailnet限定・          │
└───────────────────────────┘   暗号+ローミング)│   接続元IP許可リスト)   │
                                            └─────────────────────────┘
```

## なぜ作ったか

- **tmuxフリー**: セッション保持はWezTerm muxがサーバー側で担う。このアプリはmuxの
  ネイティブプロトコル（`codec`クレート）を直接話すので、デスクトップのWezTermと
  **同一の**workspace・タブ・ペインがiPhoneに見える
- **moshフリー**: moshの武器を分解して置換 — ローミングと暗号はWireGuard/Tailscale、
  セッション永続はmux server、と各層に委譲
- **シン**: 描画状態はサーバーが持ち、アプリは行を描いてキーを送るだけ。VTパーサも
  TLSもSSHもアプリ内に持たない

## 機能

- 名前付き接続先の複数保存
- ペイン一覧→タップでアタッチ。ペインはiPhoneの画面グリッドにリフロー
- 色・bold/italic/underline・カーソル表示
- ソフトキーボード対応、**日本語IME/フリック入力**（UITextInputで変換中テキストを
  正しく処理）、Esc / Tab / Ctrl / 矢印 / ^C のアクセサリバー
- 通常ペインはスクロールバック閲覧、マウス捕捉型のフルスクリーンTUI（例: Claude Code）
  にはホイールイベント転送（デスクトップWezTermと同じ意味論）
- 再接続に強い: 状態は全部muxが持つので、アタッチし直すだけ

## 必要なもの

| 場所 | 内容 |
|------|------|
| サーバー | Linux + `wezterm-mux-server` **20240203-110809-5046fc22** + `socat` + Tailscale |
| iPhone | iOS 18+、サーバーと**同じtailnet**に参加したTailscaleアプリ |
| ビルドマシン | macOS + Xcode 16+ + Rust (stable) + `xcodegen` |

wezterm codecのバージョンは両端で一致が必須です。このリポジトリはwezterm 20240203の
ソースツリー（iOS移植パッチ込み、[docs/UPSTREAM-CHANGES.md](docs/UPSTREAM-CHANGES.md)参照）
を同梱しており、クライアント・サーバーともcodec v42を話します。

## はじめかた

1. **サーバー**: [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md) — mux serverの導入、
   unixソケットのtailnet IPへのsocat公開、デバイス限定の絞り込み
2. **アプリのビルド**: [docs/BUILD.md](docs/BUILD.md) — Rust → XCFramework → SwiftUI。
   シミュレータ・実機両方の手順あり
3. アプリの「+」でサーバーを追加（`100.x.y.z:17778`）→ タップ → 完了

動かないときは [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) へ。開発中に実際に
踏んだ落とし穴を全部記録してあります（たくさんあります）。

## セキュリティモデル

muxプロトコルは設計上**無認証・平文**です（本来unixソケットから出ない前提のもの）。
本プロジェクトは次の三段構えで安全を確保します：

1. WireGuardの暗号化と端末識別（Tailscale）— インターネットには何も公開しない
2. socatはサーバーのtailnet IPにのみbind
3. socatの `range=` で各ポートを特定クライアントIPのみに制限

socatのポートをパブリックなインターフェースに公開しないでください。

## 状態と既知の粗さ

個人ツールとして実機でend-to-end動作済み。荒削りな部分：

- 描画はAttributedStringベース（通常用途は問題なし、巨大なスクロールバックの
  一括描画には未最適化）
- IMEの変換候補ウィンドウの表示位置が近似
- 無料Apple IDの署名は7日で失効（再ビルド＋再インストール、またはDeveloper Program加入）

## ライセンス

MIT — [LICENSE](LICENSE)参照。`wezterm/` ツリーはWez Furlong氏の成果物（MIT）に小さな
パッチを当てて同梱したものです。[NOTICE](NOTICE) と
[docs/UPSTREAM-CHANGES.md](docs/UPSTREAM-CHANGES.md) を参照してください。
