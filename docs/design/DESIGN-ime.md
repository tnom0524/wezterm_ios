# 日本語入力（IME/フリック）対応 設計書（設計: Fable 5 / 実装: Sonnet）

## ゴール
iPhoneの日本語キーボード（フリック/ローマ字）でターミナルに日本語を入力できる。
変換中テキスト（未確定文字列）はペインに送らず、確定した文字列だけをUTF-8で送信する。

## 現状の制約
`TerminalKeyView: UIView, UIKeyInput` は確定文字しか受け取れないため、IMEの変換
UI（候補表示・変換中下線）が成立しない。また `keyboardType = .asciiCapable` が
日本語キーボードの表示自体を妨げている。

## 設計: 最小UITextInput実装（"fake document"方式）

ターミナルアプリの定石（SwiftTerm等と同方式）。**ドキュメント＝変換中テキストのみ**
という極小のテキスト入力コンテキストを演じる。

### TerminalKeyView を UITextInput 準拠に拡張

内部状態:
- `markedText: String?` — 変換中文字列（nil=非変換中）
- `selectedRangeInDoc: NSRange` — ドキュメント内選択（変換中のカーソル）
- `onMarkedTextChanged: ((String?) -> Void)?` — UI表示用コールバック

主要メソッドの意味論:
- `insertText(_ text:)` — **確定**。現行ロジック（Ctrlトグル/\n→\r/UTF-8化）で送信し、
  `markedText = nil` に。onMarkedTextChanged(nil)
- `setMarkedText(_ s:, selectedRange:)` — markedText更新（送信しない）。コールバック通知
- `unmarkText()` — 変換確定扱い: markedTextが残っていればその文字列を送信してクリア
- `deleteBackward()` — markedTextがnilのときのみ 0x7f 送信（変換中の削除はIMEが
  setMarkedTextで面倒を見る）
- `hasText` — `!(markedText ?? "").isEmpty`

UITextPosition/UITextRange:
- `class TermTextPosition: UITextPosition { let offset: Int }`
- `class TermTextRange: UITextRange { let start/end: TermTextPosition }`
- ドキュメント文字列は常に `markedText ?? ""`。beginning/endOfDocument、
  `textRange(from:to:)`、`position(from:offset:)`、`compare`、`offset(from:to:)`、
  `text(in:)`、`replace(range:with:)` をこの文字列上で素直に実装
- `markedTextRange` — markedText全体のrange（nilなら nil）
- `selectedTextRange` — selectedRangeInDoc を反映
- 幾何系（`caretRect(for:)`, `firstRect(for:)`, `selectionRects(for:)`,
  `closestPosition(to:)` 等）— 自ビューのboundsベースのダミー矩形/位置でよい
  （候補ウィンドウの位置決めに使われるだけ。クラッシュしない値を返すこと）
- `tokenizer` — `UITextInputStringTokenizer(textInput: self)`
- `inputDelegate` — プロパティとして保持。markedText変更の前後で
  `textWillChange/textDidChange`・`selectionWillChange/selectionDidChange` を呼ぶ
- スタイル系・辞書系でOptionalなものは未実装(nil/空)でよい

### UITextInputTraits変更
- `keyboardType: .default`（.asciiCapableを廃止 — 日本語キーボードを出すため）
- autocorrection/smartQuotes等の抑制は現状維持（IME変換とは独立）

### 変換中テキストのUI表示
- `TerminalKeyInput`(UIViewRepresentable)に `@Binding var composingText: String?` を追加
  し、onMarkedTextChangedで反映
- `KeyInputView` のアクセサリバーの**上**に、composingText非nilのとき小さな
  ストリップを重ねて表示（等幅フォント・下線付き・背景 Color(white:0.25)）。
  ターミナル描画への埋め込みはv2（今回はやらない）
- TerminalViewへの変更は composingText の配線程度に留める

## 検証
- ビルド: xcodebuild成功 → simctl install/launch クラッシュなし
- ASCII回帰が最重要: 英字入力・Backspace・Enter・Ctrl・矢印バーが従来通り動くこと
  （シミュレータ起動して目視できる範囲で。実ペインへの送信テストは不可 —
  ビルド＋起動＋コードレビューレベルで担保し、最終確認はユーザー）
- 日本語入力の実機的検証はユーザーが行う（シミュレータで日本語キーボード追加:
  Settings > General > Keyboard > Add New Keyboard > Japanese Kana。手順をレポートに含める）

## 既知のリスク
- ドキュメントが空のときにdeleteBackwardが呼ばれなくなるIME実装がある。
  Backspaceが死んだ場合はセンチネル文字方式（ドキュメント先頭に不可視の1文字を
  常駐させ、それが消されたら0x7f送信＋復元）に切り替える
- Return確定直後のEnterが「確定」と「改行送信」のどちらに落ちるかはIME挙動依存。
  insertText("\n")が来た場合のみ\r送信（現行ロジック）で自然になるはず
