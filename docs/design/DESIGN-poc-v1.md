# poc-attach v1 設計書（設計: Fable 5 / 実装: Opus）

## ゴール

v0（読み取りのみ）を、**インタラクティブなターミナルクライアント**に拡張する。
これはiOSアプリのRustコア層の原型となる。証明したいこと：

1. キー入力を送れる（`WriteToPane`）
2. サーバーのプッシュ（serial=0の`GetPaneRenderChangesResponse`）で画面を追従できる
3. トランスポートを差し替えられる（ssh子プロセス ⇔ 素のTCP）← iOSはTCP側を使う

## CLI仕様

```
poc-attach <transport> <mode>
  transport:  ssh <host>          # ssh -T <host> "wezterm cli --prefer-mux proxy"
              tcp <addr:port>     # TcpStream直結（サーバー側でunixソケットをsocatでTCP公開）
  mode:       list                # v0相当（ハンドシェイク+ListPanes+GetLines）回帰テスト用
              attach [pane_id]    # インタラクティブ接続（省略時はis_active_paneなペイン）
              selftest            # 自動テスト（下記）
```

## アーキテクチャ

```
Transport trait（Read半分 + Write半分に分離できること）
  ├─ SshTransport: Child stdin/stdout（-T必須。ttyはバイナリを壊す）
  └─ TcpTransport: TcpStream（try_clone()でread/write分離）

読みスレッド: Pdu::decode ループ → mpsc::channel<DecodedPdu>
  - serial != 0 → RPC応答（待機中のリクエストへ）
  - serial == 0 → 一方的通知（イベントとしてメインループへ）
書き込み: Mutex<W>で encode + flush

PaneState（attachとselftestで共用すること。iOSコアの原型なので）
  - lines: HashMap<StableRowIndex, Line>
  - dims: RenderableDimensions / cursor: StableCursorPosition
  - apply_delta(GetPaneRenderChangesResponse):
      bonus_lines.extract_data() を lines に反映、dims/cursor更新、
      bonus_linesでカバーされないdirty_lines範囲を GetLines で取得
  - render_to_string(): viewport（physical_top..physical_top+viewport_rows）を
      ANSIエスケープ付き文字列に描画（後述）
```

## プロトコルフロー（attach）

1. `GetCodecVersion` ハンドシェイク（codec_vers==42を検証、不一致はエラー終了）
2. `SetClientId`（`mux::client::ClientId::new()`）
3. `ListPanes` → 対象ペインの pane_id / tab_id / size を得る
4. `GetPaneRenderChanges { pane_id }` を1回送る（サーバー側のper-pane追跡を起動、
   以後はサーバーが変更を勝手にプッシュしてくる）
5. ループ：
   - 通知 `GetPaneRenderChangesResponse`（対象pane）→ PaneState::apply_delta → 再描画
   - `SetPalette`/`NotifyAlert`/`PaneFocused` → 無視（bailしないこと）
   - `PaneRemoved`（対象pane）→ 綺麗に終了
   - stdinスレッドからのバイト → `WriteToPane { pane_id, data }`
6. 終了キー: **Ctrl-]** (0x1D)。それ以外の全バイトは素通しで送る

## ローカル端末制御（attachモード）

- termios raw mode（libc::tcgetattr/tcsetattr）。終了時・panic時に必ず復元
  （panicフックまたはDropガード）
- 描画は毎回フル再描画でよい（v1は正しさ優先）:
  `CSI 2J` は使わず `CSI H` + 各行 `CSI K` で行単位クリア、最後にカーソル位置を
  `cursor_position`（viewport相対に変換: row - physical_top）へ `CSI <r>;<c>H`
- SGR: `Line::visible_cells()` の `CellAttributes` から最低限
  fg/bg色（AnsiColor/256/TrueColor）、bold、underline、reverse を出す。
  それ以外の属性は無視してよい
- SIGWINCH → ioctl TIOCGWINSZ → `Resize { containing_tab_id, pane_id, size }`

## selftest（エージェントの検証手段。ユーザーの既存ペインに触らないこと！）

1. ハンドシェイク + SetClientId
2. `SpawnV2 { domain: SpawnTabDomain::DefaultDomain, window_id: None,
   command: None, command_dir: None, size: 80x24, workspace: "poctest" }`
   → SpawnResponse から pane_id を得る（**この自分で作ったpane以外に絶対に書き込まない**）
3. `GetPaneRenderChanges` で追跡開始 → `WriteToPane` で `echo hello-poc-12345\r` を送信
4. プッシュを受けて PaneState を更新（タイムアウト10秒）
5. `render_to_string()` に `hello-poc-12345` が現れたら `KillPane` で後片付けして
   `SELFTEST OK` を出力、exit 0。失敗時は診断情報を出して exit 1

## 実装上の注意

- ワークスペースルート: `<repo-root>/wezterm/`（gitリポジトリではない）
- ビルド: `source ~/.cargo/env; cargo build -p poc-attach`（ルートで）
- poc-attach/ 以外のweztermソースは変更禁止（互換fixは適用済み:
  config/src/lua.rs の `.eval::<()>()`、chrono clock featureはpoc-attach側で有効化済み）。
  もし他クレートで同種のnever-type-fallbackエラーが出たら、同様の最小型注釈のみ可
- 依存追加はpoc-attach/Cargo.tomlのみ可（libc, signal-hook等は自由。既存: anyhow/codec/mux/termwiz/chrono）
- コメントは既存main.rsに合わせて日本語
- `Pdu::encode(&self, w, serial)` / `Pdu::decode(r) -> DecodedPdu` は同期版を使う
- 検証: ①`cargo build -p poc-attach` ②`./target/debug/poc-attach ssh bd-anno list`
  ③`./target/debug/poc-attach ssh bd-anno selftest` の3つが通ること
- attachモードの対話部分は自動テスト不可なので、コンパイルが通ること＋
  selftestがrender/入力/プッシュの同じコードパスを通ることで担保する
