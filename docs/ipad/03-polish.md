# フェーズ 3: iPad ポリッシュ（フォントサイズ可変 + トラックパッドホイール）

## 3-A: フォントサイズ可変（ピンチ + 永続化）

### 現状の問題

フォントメトリクスが `TerminalView.swift` の file-private 定数
（`terminalFontSize` = 14pt 固定、`terminalBaseFont`、`terminalCellSize`）で、
13" iPad では小さすぎる。`CopySheetView` も 14pt を直書きしている。

### 設計: `TerminalStyle`（新規ファイル `ios/WeztermMobile/TerminalStyle.swift`）

```swift
/// ターミナルのフォントメトリクス一元管理。fontSize 変更で全描画とグリッド計算が追従する。
@MainActor
final class TerminalStyle: ObservableObject {
    static let minSize: CGFloat = 10
    static let maxSize: CGFloat = 24

    @Published var fontSize: CGFloat {
        didSet {
            let clamped = min(Self.maxSize, max(Self.minSize, fontSize.rounded()))
            if clamped != fontSize { fontSize = clamped; return }
            UserDefaults.standard.set(Double(fontSize), forKey: "terminal.fontSize")
        }
    }

    var baseFont: UIFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    /// 1 セルの実測寸法（幅 = "W" のレンダリング幅、高さ = lineHeight）
    var cellSize: CGSize {
        let w = NSAttributedString(string: "W", attributes: [.font: baseFont]).size().width
        return CGSize(width: w, height: baseFont.lineHeight)
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: "terminal.fontSize")
        let deviceDefault: CGFloat =
            UIDevice.current.userInterfaceIdiom == .pad ? 16 : 14
        fontSize = saved > 0 ? CGFloat(saved) : deviceDefault
    }
}
```

### 組み込み

- `TerminalView` に `@StateObject private var style = TerminalStyle()`。
  file-private 定数 3 つ（`terminalFontSize` / `terminalBaseFont` /
  `terminalCellSize`）への参照をすべて `style.fontSize` / `style.baseFont` /
  `style.cellSize` に置換する。定数は削除
  - 注意: `buildPlainText` などの free function は metrics を使っていないので無関係
  - 注意: `cellSize` は呼び出し頻度が高い（スクロールジオメトリ計算）。
    毎回 NSAttributedString を作らないよう、`fontSize` の didSet でキャッシュを
    再計算する実装に変えてよい（`@Published private(set) var cellSize` 化）
- `Text` の `.font(.system(.body, design: .monospaced))` になっている箇所
  （historyContent / terminalText）は AttributedString 側のフォントが実効値
  なので実害はないが、`.font(Font(style.baseFont))` に揃えること
- **フォントサイズ変更時にグリッド再計算**: `.onChange(of: style.fontSize)` で
  `scheduleResize(for: geo.size, immediate: true)` を呼ぶ。ただし
  `lastSentGrid` 比較は cols/rows ベースなので同値ならスキップされる（既存挙動）
- `CopySheetView` は等幅 14pt 直書きが 1 箇所（`makeUIView`）。
  `CopySheetView(text:loadOlder:fontSize:)` に引数追加し `TerminalView` の
  `openCopySheet` から `style.fontSize` を渡す（デフォルト引数 14 で互換維持）

### ピンチジェスチャ

`scrollableTerminal` に `MagnifyGesture` を simultaneousGesture で追加:

```swift
@State private var pinchBaseFontSize: CGFloat? = nil

.simultaneousGesture(
    MagnifyGesture()
        .onChanged { value in
            if pinchBaseFontSize == nil { pinchBaseFontSize = style.fontSize }
            style.fontSize = (pinchBaseFontSize! * value.magnification).rounded()
        }
        .onEnded { _ in pinchBaseFontSize = nil }
)
```

- clamp は `TerminalStyle.didSet` に任せる
- mouseGrabbed ペインでも有効（表示サイズはクライアント都合）
- ピンチ中は 2 本指なので `onScrollPhaseChange` の凍結と共存する（問題があれば
  ピンチ中のみ `store.setRenderFrozen(true)` を明示）

## 3-B: トラックパッド / マウスホイールの転送（mouseGrabbed ペイン）

### 現状の問題

- 通常ペイン: SwiftUI の ScrollView がトラックパッド 2 本指スクロールを
  ネイティブ処理する → **変更不要（受け入れ項目で確認のみ）**
- mouseGrabbed ペイン（TUI、`scrollDisabled(true)`）: 指ドラッグは
  `DragGesture` で SGR ホイールに変換しているが、トラックパッドの
  2 本指スクロール（indirect pointer）は DragGesture に届かない可能性が高い
  （スパイクで確認）

### 設計: `Pad/ScrollWheelCatcher.swift`

透明な UIViewRepresentable オーバーレイ。`UIPanGestureRecognizer` の
`allowedScrollTypesMask = [.discrete, .continuous]` でホイール/2 本指
スクロールだけを拾い、1 行分の移動量ごとに SGR ホイールイベントを送る:

```swift
struct ScrollWheelCatcher: UIViewRepresentable {
    let cellHeight: CGFloat
    let onWheel: (_ up: Bool, _ steps: Int) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.onPan(_:)))
        pan.allowedScrollTypesMask = [.discrete, .continuous]
        pan.allowedTouchTypes = []        // 直接タッチは拾わない（指は既存 DragGesture の領分）
        pan.maximumNumberOfTouches = 0    // indirect スクロールのみ
        v.addGestureRecognizer(pan)
        return v
    }
    // Coordinator.onPan: translation.y を蓄積し、cellHeight ごとに
    // onWheel(up: 累積が正, steps: n) → 蓄積から n*cellHeight を減算。
    // .ended/.cancelled で蓄積リセット。
}
```

- `TerminalView.scrollableTerminal` で `snap.mouseGrabbed` のときのみ
  ZStack オーバーレイとして載せる。`onWheel` は既存 `sendScrollEvent(snap:up:)` を
  steps 回呼ぶだけ
- 方向規約は既存の DragGesture と同一に揃える（translation 正 = 過去方向 = up）
- `allowedTouchTypes = []` + `maximumNumberOfTouches = 0` の組で
  「スクロールイベントのみ拾う」の意図。実機/シミュレータで指タッチを
  奪っていないことを必ず確認（奪う場合は `cancelsTouchesInView = false` を併用）

## 受け入れチェックリスト

### 3-A
- [ ] ピンチでフォントが 10–24pt の範囲で滑らかに変わり、cols/rows が追従する
      （拡大 → 列数減、サーバ側リフローが起きる）
- [ ] アプリ再起動後もフォントサイズが保持されている
- [ ] iPad 初回起動のデフォルトが 16pt、iPhone は 14pt
- [ ] コピーシートのフォントサイズがターミナルと一致する
- [ ] カーソル位置（セル幅計算）がフォントサイズ変更後も正しい
- [ ] iPhone でピンチしても既存のスクロール・長押しコピーと干渉しない

### 3-B
- [ ] 通常ペイン: トラックパッド 2 本指スクロールでローカル履歴スクロール（無変更で動くはず）
- [ ] mouseGrabbed ペイン（例: htop, claude /tui fullscreen）: 2 本指スクロールで
      アプリ側スクロールが動く
- [ ] 指ドラッグの既存転送が引き続き動く（Catcher が触っていない）
- [ ] iPhone で回帰なし（Catcher は mouseGrabbed 時のみ搭載だが指タッチを奪わないこと）
