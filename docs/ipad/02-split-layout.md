# フェーズ 2: iPad レイアウト（NavigationSplitView）

iPad では「サイドバー（接続先 + ペイン一覧）｜ターミナル」の 2 カラム構成にする。
ペイン切替がプッシュ遷移の往復なしにワンタップで完結するのが価値。
iPhone のフローは一切変えない。

## 分岐方針

idiom で分岐する（サイズクラスでは分岐しない — PLAN.md 運用ルール 4）:

```swift
// WeztermMobileApp.swift
var body: some Scene {
    WindowGroup {
        if UIDevice.current.userInterfaceIdiom == .pad {
            PadRootView()
        } else {
            ConnectView()   // iPhone: 既存フローそのまま
        }
    }
}
```

## 新規ファイル（`ios/WeztermMobile/Pad/` 配下）

### `Pad/PadRootView.swift`

```swift
struct PadRootView: View {
    @StateObject private var listStore = ConnectionListStore()
    @StateObject private var store = ConnectionStore()
    @State private var selectedPane: PaneInfo? = nil
    @State private var connectedAddr: String = ""   // 再接続用

    var body: some View {
        NavigationSplitView {
            PadSidebarView(listStore: listStore,
                           store: store,
                           selectedPane: $selectedPane,
                           connectedAddr: $connectedAddr)
        } detail: {
            if let pane = selectedPane {
                TerminalView(store: store, pane: pane)
                    .id(pane.paneId)   // ← 必須。下記「.id の理由」参照
            } else {
                ContentUnavailableView("ペインを選択",
                                       systemImage: "terminal",
                                       description: Text("サイドバーから接続してペインを選んでください"))
            }
        }
        .preferredColorScheme(.dark)
    }
}
```

**`.id(pane.paneId)` の理由**: `TerminalView` はペイン固有の `@State`
（`lastSentGrid` / `isAtBottom` / `composingText` など）を持つ。id を変えて
ビューごと作り直さないと前ペインの状態が持ち越されてリサイズ抑止などが誤動作する。

### `Pad/PadSidebarView.swift`

`List(selection:)` ベース。2 セクション構成:

1. **接続先セクション**（`ConnectionListStore` 由来）
   - 行 UI・スワイプ編集/削除・追加シートは `ConnectView` のものを踏襲。
     共通化のため `ConnectView.swift` から行ラベル部分
     （名前 + アドレスの VStack）を小さな `ConnectionRowLabel` view に抽出して
     両方から使ってよい（挙動を変えない純粋な抽出のみ許可）
   - タップで `store.makeConnection(addr:)`。接続中は ProgressView。
     成功したら `connectedAddr` を保存しペイン一覧を refresh
   - 接続済みの行にはインジケータ（例: 緑の点）+「切断」コンテキストメニュー
2. **ペインセクション**（`store.isConnected` のときのみ表示）
   - `PaneListView` の行 UI（Pane番号 / title / cols×rows / active 点）を踏襲
   - タップで下記 `switchPane` → `selectedPane = pane`
   - ツールバーに Refresh ボタン（既存 `refreshPanes`）
   - 切断バナー相当: `store.disconnectReason != nil` のとき再接続ボタンを
     セクション内に表示（`store.reconnect(addr: connectedAddr)`）

`ConnectView` / `PaneListView` 本体の挙動は変更しない（iPhone 用にそのまま残す）。

## `ConnectionStore` への追加: `switchPane`

ペイン切替時に **ペイン固有状態のリセット**が必須。`rowCache` のキー
（StableRowIndex）はペイン間で衝突するため、リセットせずに切り替えると
前ペインの履歴行が混入して表示が化ける。

```swift
/// 別ペインへ attach し直す。ペイン固有のキャッシュ・描画状態をすべてリセットする。
func switchPane(to pane: PaneInfo) async {
    guard pane.paneId != attachedPaneId else { return }
    // 描画スロットル状態
    renderTask?.cancel()
    renderTask = nil
    pendingSnapshot = nil
    renderFrozen = false
    lastRenderAt = nil
    // ペイン固有キャッシュ（disconnect() のリセット項目と揃える）
    snapshot = nil
    rowCache = [:]
    physicalTop = 0
    scrollbackTop = 0
    loadedHistoryTop = 0
    attachedPaneId = nil   // 旧ペインの snapshot 到着を即座に遮断
    await attach(pane: pane)
}
```

注意点:
- `attachedPaneId = nil` を attach の**前**に行う（旧ペインの配信は Rust 側で
  止まらないため、`handleSnapshot` のフィルタで捨てる。lib.rs の `do_attach` は
  ペイン単位に購読を張り、旧購読は残る仕様 — v1 ではこの帯域は許容）
- リセット後の初回 snapshot で `loadedHistoryTop == 0` ガードが効いて
  `physicalTop` に初期化され、prefetch（500 行）も `isFirstSnapshot` 経由で再走する。
  既存ロジックがそのまま正しく動くことがこのリセット設計の狙い
- `PadSidebarView` のペイン行タップは `attach(pane:)` ではなく必ず
  `switchPane(to:)` を呼ぶ。iPhone 側 `PaneListView` は従来どおり `attach` のまま
  （NavigationStack で戻る→入るの間に別ペインへ行くケースは iPad 化とは独立の
  既知課題として温存。挙動を変えない）

## TerminalView の軽微な調整

- `navigationTitle` / toolbar は NavigationSplitView の detail 側でもそのまま出る。
  変更不要（確認のみ）
- サイドバーの表示/非表示トグルで detail 幅が変わる → `GeometryReader` +
  `scheduleResize`（0.5s デバウンス）が追従する。変更不要（確認のみ）

## 受け入れチェックリスト

- [ ] iPad: 起動 → サイドバーに接続先一覧 → タップで接続 → ペイン一覧が
      サイドバーに出る → タップでターミナル表示
- [ ] ペイン A → B → A と切り替えても表示・履歴・スクロールが正しい
      （行の混入・グリッド寸法の引き継ぎ事故がない）
- [ ] ペイン切替後にスクロールバック（上スクロール）すると新ペインの履歴が出る
- [ ] サイドバー開閉でターミナルの cols/rows が追従する
- [ ] 切断 → サイドバーから再接続できる
- [ ] 接続先の追加・編集・削除がサイドバーからできる
- [ ] 縦向き iPad: サイドバーがオーバーレイになってもターミナル操作に支障がない
- [ ] iPhone: 従来フロー（ConnectView → PaneListView → TerminalView）が無変化
- [ ] Slide Over（compact 幅）でも iPad UI のまま破綻しない
