# WezTerm iOSクライアント 全体設計（設計: Fable 5 / 実装: Opus）

## コンセプト

moshi(mosh+tmux)を置き換える、wezterm muxのネイティブiOSシンクライアント。

```
iPhone                                       bd-anno (EC2)
┌────────────────────────┐                  ┌──────────────────────┐
│ SwiftUI (描画・キーボード) │                  │ wezterm-mux-server    │
│   ↕ UniFFI              │   Tailscale      │   ↕ unix socket      │
│ Rustコア                 │══════════════════│ socat TCP:17777      │
│  codec/PaneState/TCP    │  (WireGuardが     │  (tailnet内限定)      │
└────────────────────────┘   暗号+ローミング)  └──────────────────────┘
```

- 暗号・認証・ローミング: **すべてTailscale(WireGuard)層に委譲**（Step1で実証済み）
  → アプリにはSSHスタックもTLSも証明書も持たない。素のTCPのみ
- プロトコル: codecクレート直叩き（Step2/poc-attach v1で実証済み）
- サーバー状態保持: mux-serverがscrollback含め全部持つ。クライアントは薄い

## レイヤー構成

### 1. Rustコア（新クレート `wezterm-ios-core`、weztermワークスペース内）

poc-attach v1の Transport/PaneState を土台に、UniFFIでSwiftに公開する。

公開API（uniffi proc-macroモード、UDLファイル不使用）:
```
connect(addr: String, delegate: ClientDelegate) -> Arc<MuxClient>   // TCP接続+ハンドシェイク+SetClientId
MuxClient::list_panes() -> Vec<PaneInfo>        // pane_id/tab_id/title/active/size/workspace
MuxClient::attach(pane_id, cols, rows)          // GetPaneRenderChanges購読開始 + Resize
MuxClient::send_input(pane_id, data: Vec<u8>)   // WriteToPane
MuxClient::resize(pane_id, tab_id, cols, rows)
MuxClient::disconnect()

callback interface ClientDelegate:
  on_snapshot(pane_id: u64, snap: Snapshot)     // 画面更新（フルviewport）
  on_disconnected(reason: String)
```

Snapshot（Swiftを愚直に保つため、色解決はRust側で完結させる）:
```
Snapshot { rows: Vec<Row>, cursor_row: i32, cursor_col: i32, cols: u32, view_rows: u32 }
Row { spans: Vec<Span> }
Span { text: String, fg: u32 /*0xRRGGBBAA*/, bg: u32, flags: u8 /*bold|underline|reverse|italic*/ }
```
- 内部: 読みスレッドがPdu decode→PaneState適用→Line+ColorPalette→Span変換→delegate呼び出し
- SetPaletteプッシュを保持しfg/bg解決に使う（未受信時はColorPalette::default()）
- 再接続: disconnect検知→delegateに通知。再connectは上位(Swift)の責務（muxが状態を持つので安い）

### 2. Swift側（SwiftUI、iOS 17+）

- `ConnectionStore: ObservableObject` — コアのdelegate実装。UniFFIコールバックはRustスレッドから来るため必ずMainActorへhopしてから@Publishedを更新
- 画面: ConnectView（アドレス入力、既定値 100.64.0.1:17777）→ PaneListView → TerminalView
- TerminalView v1: SnapshotをAttributedStringに変換し等幅フォントで表示（Canvas/Metal最適化はv2）
- キーボード: 非表示UITextField(UIKeyInput)で通常キー、上部アクセサリバーに Esc/Tab/Ctrl(トグル)/矢印/Ctrl-C — **moshiの不満点だった特殊キーを一等市民にする**
- ライフサイクル: scenePhase→backgroundで切断は放置、activeで自動再接続+再attach

### 3. サーバー側（設定済み・2026-07-07）

- socat: `TCP4-LISTEN:17777,bind=100.64.0.1,reuseaddr,fork,range=<許可IP>/32 UNIX-CONNECT:/run/user/1000/wezterm/sock`（nohup起動中。EC2再起動時はmux-serverともども手動再起動が必要）
- 現在の許可元はMac(100.64.0.10)のみ。**シミュレータはMacのネットワークを共有するのでこのままテスト可能**
- 実機化の際: iPhone(100.64.0.11)向けに別ポートでsocatをもう1本 or Tailscale ACLに移行

## ビルド段取り

- C-1: `wezterm-ios-core` をまず **macOSホスト向け**にビルドし、スモークテストバイナリ
  （examples/smoke.rs: TCP接続→list→attach→スナップショット1枚をテキストダンプ）で検証
- C-2: Xcodeインストール後: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`
  → staticlib + uniffi-bindgen → XCFramework → SwiftUIアプリ（**まずシミュレータ**。署名不要）
- C-3: 実機（Apple ID署名、iPhoneのTailscale(<your-account>プロファイル)有効化、socat許可追加）

## 既知のリスクと方針

- mlua(vendored lua54)/zstd のiOSクロスコンパイル: 実績はあるがcc周りで揉めたら、
  iOS SDKのclangをCC環境変数で明示。最悪configクレートの依存を外す改造も視野（codecの
  config依存はkeyassignment型のみなので切り出し可能）
- procinfo/portable-ptyがiOSでコンパイル不能な場合: スタブ化（コンパイルさえ通れば実行時未使用）
- codec_versペア(42)の維持: サーバーを更新したらアプリも同一タグから再ビルド
