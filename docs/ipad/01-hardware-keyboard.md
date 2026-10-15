# フェーズ 1: ハードウェアキーボード対応

Magic Keyboard / Bluetooth キーボードで、ターミナルとして自然な打鍵体験を作る。
iPad 体験の価値の大半はここにある（同時に iPhone + BT キーボードでも効く）。

## 大原則（違反 = 即やり直し）

1. **IME 機構の不可侵**: `TerminalKeyView` の既存 UITextInput 実装
   （fake document / setMarkedText / insertText / position・range 系）は
   1 行も変更しない。このフェーズの実装はすべて **追加**（新規ファイルの
   extension + 新規コールバックプロパティ）で行う
2. **IME 変換中（`markedText != nil`）はキー横取りを全面停止**:
   変換中の矢印（候補選択）・Space（変換）・Return（確定）・Esc（変換取消）は
   すべて IME のものであり、1 バイトたりとも端末に送ってはならない。
   ※ `markedText` は private なので、extension から参照できる読み取り用の
   computed property `var isComposing: Bool { markedText != nil }` を
   `KeyInputView.swift` の class 本体に **1 行だけ追加**することを許可する
3. **二重送信の禁止**: UITextInput 経由で既に届くキーは横取りしない。
   横取りしたキーは `super` に渡さない。1 打鍵 = 1 送信を厳守

## ステップ 1: スパイク（実装前に必ずやる）

矢印キーと Ctrl+A がどの経路で届くかを実測してから本実装に入る。
UIKit のキー配送は first responder が UITextInput か否かで挙動が変わり、
文献では確定できないため。

`TerminalKeyView` に一時的なログを仕込む:

```swift
// spike: 後で消す
override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for p in presses {
        print("SPIKE pressesBegan:", p.key?.keyCode ?? .none,
              p.key?.modifierFlags ?? [], p.key?.charactersIgnoringModifiers ?? "")
    }
    super.pressesBegan(presses, with: event)
}
```

シミュレータで I/O > Keyboard > Send Keyboard Input to Device を ON にして
矢印 / Esc / Ctrl+A / Cmd+V / 通常文字 / 日本語変換中の矢印 を打鍵し、
**(a) pressesBegan に届くか (b) insertText に届くか (c) どちらにも届かないか** を記録。

- 矢印が pressesBegan に届く → 方式 A（pressesBegan 主体）で実装
- 届かない → 方式 B（`keyCommands` + `wantsPriorityOverSystemBehavior = true`）で実装
- **長押しリピートの有無もここで実測する**（矢印を 2 秒押し続けて発火回数を確認）

スパイク結果はこのドキュメントの末尾に追記してから本実装に進むこと。

## ステップ 2: 本実装

新規ファイル `ios/WeztermMobile/TerminalKeyView+HardwareKeys.swift` に
extension として実装する（`pressesBegan` / `pressesEnded` / `keyCommands` は
UIKit の @objc メソッドなので extension からの override が可能）。

### キーマッピング表（横取りして送信するもの）

| 物理キー | 条件 | 送信バイト列 |
|---|---|---|
| ↑ | 非変換中 | `1B 5B 41` |
| ↓ | 非変換中 | `1B 5B 42` |
| → | 非変換中 | `1B 5B 43` |
| ← | 非変換中 | `1B 5B 44` |
| Esc | 非変換中 | `1B` |
| Home | 非変換中 | `1B 5B 48` |
| End | 非変換中 | `1B 5B 46` |
| PageUp | 非変換中 | `1B 5B 35 7E` |
| PageDown | 非変換中 | `1B 5B 36 7E` |
| 前方Delete (fn+⌫) | 非変換中 | `1B 5B 33 7E` |
| Ctrl + `@ A-Z [ \ ] ^ _` | 非変換中 | `charactersIgnoringModifiers` の ASCII `& 0x1F`（1 バイト） |
| Ctrl + Space | 非変換中 | `00` |

Ctrl 組み合わせの実装メモ: `key.charactersIgnoringModifiers` を小文字化 →
ASCII 値が `0x40...0x7E` なら `& 0x1F`。既存のソフトキー Ctrl トグルと同じ変換式
（`insertText` 内の ctrlMode 処理を参照。ただしそのコードは変更しない）。

### 横取りしないもの（UITextInput に流す = `super` へ）

- 通常文字・Shift 文字・Option 文字（アクセント/記号入力として自然に入る）
- Return（`insertText("\n")` → 既存ロジックが `\r` 化）
- Tab（`insertText("\t")` で届く — スパイクで要確認。届かなければマッピング表に追加: `09`）
- Backspace（`deleteBackward()` で届く）
- 変換中のすべてのキー
- Cmd 系（下記のショートカットで処理するもの以外はシステムに任せる)

### Cmd ショートカット

`keyCommands` で提供（こちらは変換中でも有効でよい。IME は Cmd を使わない）:

| ショートカット | 動作 |
|---|---|
| Cmd+V | `onPasteRequested?()` を呼ぶ |
| Cmd+C | `onCopyRequested?()` を呼ぶ（コピーシートを開く） |

`UIKeyCommand` には `title` と `discoverabilityTitle` を設定する
（iPad で Cmd 長押しの HUD に出る）。`wantsPriorityOverSystemBehavior = true` を
設定（システムの Cmd+C デフォルト処理より優先させる）。

### 新規コールバックの配線

```
TerminalKeyView（追加プロパティ）
  var onPasteRequested: (() -> Void)?
  var onCopyRequested:  (() -> Void)?
      │ TerminalKeyInput.updateUIView で設定
      ▼
KeyInputView に引数追加: let onCopyRequest: () -> Void
  - onPasteRequested → 既存のペーストボタンと同じ処理
    （UIPasteboard.general.string → store.sendPaste）
  - onCopyRequested  → onCopyRequest()
      │
      ▼
TerminalView から KeyInputView(store:isKeyboardShown:composingText:onCopyRequest:)
  onCopyRequest = { if let snap = store.snapshot { openCopySheet(snap: snap) } }
```

呼び出し側（`TerminalView.swift` / `KeyInputView.swift` struct 部分）の変更は
この配線のみ。デフォルト引数 `onCopyRequest: () -> Void = {}` にすれば
既存呼び出しを壊さない。

### キーリピート（スパイク結果次第のフォールバック）

方式 A/B どちらでも長押しリピートが発火しない場合のみ実装する:

- `pressesBegan` で対象キーを送信しつつ `repeatTimer` 開始
  （初回遅延 0.4s → 以後 1/30s 間隔で同バイト列を再送）
- `pressesEnded` / `pressesCancelled` で必ずタイマ破棄
- 対象は矢印・前方 Delete のみ（Ctrl 組み合わせはリピート不要）
- タイマは `Timer.scheduledTimer` + `[weak self]`。`resignFirstResponder` でも破棄

## 動作確認手順

シミュレータ（Send Keyboard Input to Device ON）で:

```bash
# サーバ側で確認用に起動しておくもの: vim, less <長いファイル>, claude (/tui default)
```

## 受け入れチェックリスト

- [ ] vim で矢印移動・Esc・`:q` が物理キーボードだけで完結する
- [ ] Ctrl+C で実行中プロセスが中断できる / Ctrl+R で履歴検索が開く
- [ ] less で PageUp/PageDown・q が効く
- [ ] 矢印長押しでリピートする
- [ ] Cmd+V でクリップボードがペーストされる（ブラケットペースト経由）
- [ ] Cmd+C でコピーシートが開く
- [ ] **日本語 IME（ソフトキーボード）**: 変換・候補選択・確定が従来どおり
- [ ] **日本語 IME（ハードウェアキーボード、ローマ字入力)**: Space 変換 →
      矢印で候補選択 → Return 確定が動き、**変換中の矢印が端末に漏れない**
      （vim を開いた状態で変換操作をしてカーソルが動かないことを確認）
- [ ] 変換中に Esc → 変換キャンセルになる（端末に 1B が飛ばない）
- [ ] ソフトキーボードのみの iPhone で従来の全操作が無変化（回帰確認)
- [ ] Claude Code（/tui default）で通常入力・矢印での履歴呼び出しが動く
- [ ] スパイク用の print を消した

## スパイク結果記録

**実測 2026-07-13（iPad Pro 11 sim + Mac キーボード転送、Fable 実施）:**

- `pressesBegan` は**全キーを受信する**: 通常文字（keyCode 27 'x'、その後
  insertText にも到達）、矢印（keyCode 82/80）、Esc（41）、Ctrl 修飾単体（224）、
  Ctrl+C（keyCode 6, mods=0x40000, ignMod='c'）
- 登録済み `keyCommands` は**同じ打鍵で pressesBegan と両方発火する**
  → 併用すると二重処理。**採用方式: pressesBegan 単独**。keyCommands は
  Cmd+V / Cmd+C 専用（テキスト入力と衝突しない）
- **矢印等の特殊キーは `charactersIgnoringModifiers` が
  `'UIKeyInputUpArrow'` という複数文字の文字列になる** → 特殊キー判定は
  `key.keyCode`（`UIKeyboardHIDUsage`: `.keyboardUpArrow` 等）で行うこと
- PageDown はシミュレータ転送では観測されなかった（Magic Keyboard にも物理キー
  なし）。マッピングは実装するが自動検証対象外
- キーリピートは合成イベントでは検証不可 → **v1 はリピータなしで実装**し、
  実キーボードの長押しで確認。リピートしなければ自前タイマ（本文のフォール
  バック設計）を後付けする。システムリピートがある場合に自前タイマを重ねると
  二重になるため、先に実測すること

**設計への反映（本文の「方式 A/B」記述より本記録が優先）:**
- 横取りは `pressesBegan` のみで実装。処理したキーは `super` を呼ばず消費、
  未処理キーは必ず `super.pressesBegan` へ（テキスト入力・IME の生命線）
- 特殊キー = keyCode で判定、Ctrl 組み合わせ = `modifierFlags.contains(.control)`
  && ignMod が単一 ASCII、で判定
- `keyCommands` は Cmd+V / Cmd+C の 2 つだけ返す（`wantsPriorityOverSystemBehavior
  = true`、title 設定）。Cmd 系は pressesBegan では処理しない

## 実装・検証状況（2026-07-13）

- ✅ 実装完了（Sonnet）: `TerminalKeyView+HardwareKeys.swift` + 配線。レビュー済み・ビルド緑
- ✅ ヘッドレスで検証済み: キー配送経路（スパイク）、keyCommand アクション発火、
  Rust コアの send_input / attach / push（probe_pane.rs、テストペイン16）
- ⬜ 人手検証待ち（Mac 画面ロック中は osascript 打鍵がシミュレータに届かないため
  自動化不可）: 受け入れチェックリスト全項目。特に矢印長押しリピート・Tab 補完・
  日本語 IME（ハードキーボード）・Ctrl+Space
- 既知の軽微制限: Ctrl+矢印 は修飾なし矢印として送られる（ESC[1;5C 未対応、v2）
- 検証環境メモ: テストペインは `ssh bd-anno '... wezterm cli spawn --new-window
  --workspace ipadtest -- bash --noprofile --norc'` で作成、`--attach-pane <id>`
  起動引数で直接 attach できる（PaneListView に実装済み）。**実稼働ペインには
  絶対に打鍵テストしないこと**。診断は `wezterm-ios-core/examples/probe_pane.rs`
