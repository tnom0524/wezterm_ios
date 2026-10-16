import SwiftUI
import UIKit

// MARK: - Flag constants (must match pane_state.rs)
private let FLAG_BOLD: UInt8      = 1
private let FLAG_UNDERLINE: UInt8 = 2
private let FLAG_REVERSE: UInt8   = 4
private let FLAG_ITALIC: UInt8    = 8

// MARK: - Terminal font metrics

/// ターミナル描画に使う等幅フォント（buildAttributedString と同一サイズ）
private let terminalFontSize: CGFloat = 14
private let terminalBaseFont = UIFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)

/// 1文字セルの実測寸法。幅は "W" のレンダリング幅、高さはフォントの行高。
private let terminalCellSize: CGSize = {
    let w = NSAttributedString(
        string: "W",
        attributes: [.font: terminalBaseFont]
    ).size().width
    return CGSize(width: w, height: terminalBaseFont.lineHeight)
}()

/// ScrollView 内コンテンツの padding（左右・上下それぞれ）
private let terminalContentPadding: CGFloat = 4

// MARK: - Scroll geometry metrics (for onScrollGeometryChange)

/// onScrollGeometryChange で追跡するスクロール座標
private struct ScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentH: CGFloat
    var containerH: CGFloat
}

// MARK: - Plain text builder (free function, closure からも参照できるよう外部化)

/// ターミナルコンテンツのプレーンテキスト変換。
/// mouseGrabbed ペインは履歴非表示のためライブビューポートのみ出力する。
@MainActor
private func buildPlainText(snap: Snapshot, store: ConnectionStore) -> String {
    var lines: [String] = []

    // 1) 取得済み履歴行（mouseGrabbed 時は表示しないので含めない）
    if !snap.mouseGrabbed {
        for idx in store.loadedHistoryTop..<store.physicalTop {
            let row = store.rowCache[idx] ?? Row(spans: [])
            lines.append(row.spans.map(\.text).joined())
        }
    }

    // 2) ライブビューポート行（snapshot 由来）
    for row in snap.rows {
        lines.append(row.spans.map(\.text).joined())
    }

    // 各行末尾の空白をトリム
    lines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

    // 末尾の空行をドロップ
    while let last = lines.last, last.isEmpty {
        lines.removeLast()
    }

    return lines.joined(separator: "\n")
}

// MARK: - TerminalView

struct TerminalView: View {
    @ObservedObject var store: ConnectionStore
    let pane: PaneInfo
    /// ツールバーの「＋」から新しいペインを作ったときに呼ばれる（親が attach・画面切替を行う）
    var onPaneCreated: ((PaneInfo) -> Void)? = nil
    @State private var isKeyboardShown = false

    // MARK: Resize state
    @State private var resizeTask: Task<Void, Never>? = nil
    @State private var lastSentGrid: (cols: UInt32, rows: UInt32)? = nil

    // MARK: IME composing state
    /// 変換中テキスト（nil = IME非活性）。KeyInputView のストリップ表示に使う
    @State private var composingText: String? = nil

    // MARK: Copy sheet state
    /// コピーシートへ渡すペイロード（非 nil でシートが開く）
    @State private var copyPayload: CopyPayload? = nil
    /// コピーシートの「さらに読み込む」クロージャ（mouseGrabbed 時は nil）
    @State private var copyLoadOlder: (() async -> String?)? = nil

    // MARK: Scrollback state
    /// true = コンテンツ下端がビュー下端の 1.5 行以内（ライブ追従モード）
    @State private var isAtBottom: Bool = true
    /// true = コンテンツ上端がビュー上端の 3 行以内（追加履歴ロードトリガー）
    @State private var nearTop: Bool = false
    /// 追加ロード中フラグ（二重発行を防ぐ）
    @State private var isLoadingHistory: Bool = false
    /// ユーザー操作状態（.idle 以外は自動追従しない）
    @State private var scrollPhase: ScrollPhase = .idle
    /// ScrollView proxy を保持するためのネームスペース
    private let scrollAnchorId = "terminalBottom"

    // MARK: Scroll forwarding state
    /// 転送モード用ドラッグ累積量（1行 = cellHeight 相当で1イベント送信）
    @State private var scrollDragAccum: CGFloat = 0
    /// 直近のスクロール座標（転送モード判定に使う）
    @State private var lastScrollMetrics: ScrollMetrics = ScrollMetrics(offsetY: 0, contentH: 0, containerH: 0)


    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Group {
                    if let snap = store.snapshot {
                        ZStack(alignment: .bottomTrailing) {
                            scrollableTerminal(snap: snap, geo: geo)
                            // 履歴閲覧中に "↓ Live" ボタンを表示
                            if !isAtBottom {
                                liveButton
                            }
                        }
                    } else {
                        VStack {
                            Spacer()
                            ProgressView("Attaching pane \(pane.paneId)...")
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                            Spacer()
                        }
                    }
                }
                // attach 直後の初回サイズ確定時に即リサイズ
                .onAppear { scheduleResize(for: geo.size, immediate: true) }
                // サイズ変化（回転・キーボード表示など）はデバウンス 0.5 秒
                .onChange(of: geo.size) { _, newSize in
                    scheduleResize(for: newSize)
                }
            }

            KeyInputView(store: store,
                         isKeyboardShown: $isKeyboardShown,
                         composingText: $composingText,
                         onCopyRequest: {
                             if let snap = store.snapshot { openCopySheet(snap: snap) }
                         })
                .frame(height: 44)
        }
        .background(Color.black)
        .navigationTitle("Pane \(pane.paneId)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 新しいペイン（このペインを分割 / 同じウィンドウに新しいタブ）
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    PaneCreateMenuItems(store: store,
                                        splitTarget: pane,
                                        sameWindowAs: pane,
                                        onCreated: { onPaneCreated?($0) })
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.isConnected)
            }
            // コピーシートを開くボタン（ペインタイトルの左に配置）
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    guard let snap = store.snapshot else { return }
                    openCopySheet(snap: snap)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    // 所属タブの色ドット（ペイン一覧の色分けと対応）
                    Circle()
                        .fill(store.panes.tabColor(for: pane))
                        .frame(width: 8, height: 8)
                    Text(pane.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .sheet(item: $copyPayload) { payload in
            CopySheetView(text: payload.text, loadOlder: copyLoadOlder)
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        // 画面表示時に自動でキーボードフォーカスを取得
        .onAppear { isKeyboardShown = true }
        .onDisappear { resizeTask?.cancel() }
        // Disconnection banner
        .overlay(alignment: .top) {
            if let reason = store.disconnectReason {
                disconnectBanner(reason: reason)
            }
        }
    }

    // MARK: - Copy sheet helper

    /// コピーシートを開く。ペイロードと「さらに読み込む」クロージャをまとめてセットする。
    private func openCopySheet(snap: Snapshot) {
        copyPayload = CopyPayload(text: buildPlainText(snap: snap, store: store))
        if !snap.mouseGrabbed {
            // store はクラス参照なので直接キャプチャして問題ない
            copyLoadOlder = { [store] in
                let loaded = await store.fetchOlderHistory(chunk: 500)
                guard loaded, let currentSnap = store.snapshot else { return nil }
                return buildPlainText(snap: currentSnap, store: store)
            }
        } else {
            copyLoadOlder = nil
        }
    }

    // MARK: - Scrollable terminal with history

    @ViewBuilder
    private func scrollableTerminal(snap: Snapshot, geo: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            // 縦軸専用 ScrollView（リフロー実装済みでコンテンツ幅は画面幅に収まる）
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // 1) 履歴行（loadedHistoryTop ..< physicalTop）
                    // マウス捕捉ペイン(TUI)ではアプリ側スクロールに転送するため、
                    // ローカル履歴は表示しない（描画すると転送と二重に動いて枠がズレる）
                    if !snap.mouseGrabbed {
                        historyContent
                    }

                    // 2) ライブビューポート行（snapshot 由来）
                    terminalText(snap: snap)
                        .padding(.top, store.loadedHistoryTop < store.physicalTop ? 0 : terminalContentPadding)

                    // ボトムアンカー（自動追従用）
                    Color.clear
                        .frame(height: 1)
                        .id(scrollAnchorId)
                }
                .padding(.horizontal, terminalContentPadding)
                .padding(.bottom, terminalContentPadding)
            }
            // 初期表示を最下部にアンカー（履歴プリペンド後も下端が維持されやすい）
            .defaultScrollAnchor(.bottom)
            // マウス捕捉ペインではローカルスクロールを完全無効化（転送のみ。
            // 二重スクロールによる枠ズレ・バウンスを防ぐ）
            .scrollDisabled(snap.mouseGrabbed)
            .background(Color.black)
            .simultaneousGesture(
                TapGesture().onEnded { isKeyboardShown = true }
            )
            // ロングプレスでコピーシートを即座に開く
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    openCopySheet(snap: snap)
                }
            )
            // スクロール転送ジェスチャ: ローカル履歴がない（転送モード）ときのみ有効
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let cellH = terminalCellSize.height
                        // マウス捕捉中のアプリへは常に転送する（wezterm GUIと同じ意味論）。
                        // 非捕捉時はローカル履歴が実質ない場合のみ矢印キー変換にフォールバック。
                        let localScrollRoom = lastScrollMetrics.contentH - lastScrollMetrics.containerH
                        guard snap.mouseGrabbed || localScrollRoom < cellH * 2 else { return }
                        // scrollDragAccum = ジェスチャ開始からの「送信済みオフセット」(px)
                        // 指を下(translation正) → 上スクロール(過去を見る) = up=true
                        let pendingPx = value.translation.height - scrollDragAccum
                        let steps = Int(pendingPx / cellH)
                        guard steps != 0 else { return }
                        let upward = steps > 0
                        for _ in 0..<abs(steps) {
                            sendScrollEvent(snap: snap, up: upward)
                        }
                        scrollDragAccum += CGFloat(steps) * cellH
                    }
                    .onEnded { _ in
                        scrollDragAccum = 0
                    }
            )
            // iOS 18: スクロール座標の変化を追跡して isAtBottom / nearTop を更新
            .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                ScrollMetrics(
                    offsetY: geo.contentOffset.y,
                    contentH: geo.contentSize.height,
                    containerH: geo.containerSize.height
                )
            } action: { old, metrics in
                lastScrollMetrics = metrics
                let distanceFromBottom = metrics.contentH - metrics.offsetY - metrics.containerH
                isAtBottom = distanceFromBottom < terminalCellSize.height * 1.5
                nearTop    = metrics.offsetY < terminalCellSize.height * 3

                // 上端に近づいたら追加履歴ロード
                if nearTop && !isLoadingHistory {
                    triggerHistoryLoad()
                }
            }
            // iOS 18: ユーザー操作フェーズを追跡（操作中は自動追従しない）
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
                // mouseGrabbed ペインはサーバー再描画を止めてはならない
                if let snap = store.snapshot, !snap.mouseGrabbed {
                    store.setRenderFrozen(newPhase != .idle)
                }
            }
            // 注意: Snapshot受信ごとの proxy.scrollTo は絶対にしないこと。
            // 高頻度出力(スピナー等)でスクロールジェスチャがキャンセルされ続け、
            // スクロール操作が不可能になる。最下部への追従は defaultScrollAnchor(.bottom)
            // がジェスチャと競合せずに行う。
            .onChange(of: store.snapshot) { _, _ in
                // 履歴の先行ロード: 未取得のscrollbackが残っていて、かつロード済みが
                // 500行未満の間は自動で補充する（スクロール余地の確保）
                if !isLoadingHistory,
                   store.scrollbackTop < store.loadedHistoryTop,
                   store.physicalTop - store.loadedHistoryTop < 500 {
                    triggerHistoryLoad()
                }
            }
            // liveButtonScroll トリガー用（ユーザー操作起点のみ許可）
            .onReceive(scrollToBottomPublisher) { _ in
                withAnimation {
                    proxy.scrollTo(scrollAnchorId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - History content view

    @ViewBuilder
    private var historyContent: some View {
        let historyStart = store.loadedHistoryTop
        let historyEnd = store.physicalTop
        if historyStart < historyEnd {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(historyStart..<historyEnd, id: \.self) { idx in
                    let row = store.rowCache[idx] ?? Row(spans: [])
                    let str = buildAttributedString(row: row, cursorRow: -1, cursorCol: -1, rowIdx: 0)
                    Text(str)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.top, terminalContentPadding)
        }
    }

    // MARK: - Live button

    // Combine publisher で "scroll to bottom" を伝達するシンプルな仕組み
    private let scrollToBottomPublisher = NotificationCenter.default.publisher(
        for: Notification.Name("TerminalScrollToBottom")
    )

    private var liveButton: some View {
        Button {
            isAtBottom = true
            NotificationCenter.default.post(
                name: Notification.Name("TerminalScrollToBottom"),
                object: nil
            )
        } label: {
            Label("Live", systemImage: "arrow.down.circle.fill")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.85))
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
        .padding(12)
    }

    // MARK: - History load trigger

    private func triggerHistoryLoad() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        Task {
            await store.fetchHistory(upTo: store.loadedHistoryTop)
            isLoadingHistory = false
        }
    }

    // MARK: - Resize scheduling

    /// 利用可能領域から cols/rows を計算して resize をスケジュールする。
    private func scheduleResize(for size: CGSize, immediate: Bool = false) {
        let usableWidth = size.width - terminalContentPadding * 2
        let usableHeight = size.height - terminalContentPadding * 2
        guard usableWidth > terminalCellSize.width,
              usableHeight > terminalCellSize.height else { return }

        let cols = UInt32(max(10, Int(floor(usableWidth / terminalCellSize.width))))
        let rows = UInt32(max(4, Int(floor(usableHeight / terminalCellSize.height))))

        // 同じ寸法を再送しない
        if let last = lastSentGrid, last.cols == cols, last.rows == rows { return }

        resizeTask?.cancel()
        if immediate {
            lastSentGrid = (cols, rows)
            store.resize(paneId: pane.paneId, tabId: pane.tabId, cols: cols, rows: rows)
        } else {
            resizeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                lastSentGrid = (cols, rows)
                store.resize(paneId: pane.paneId, tabId: pane.tabId, cols: cols, rows: rows)
            }
        }
    }

    // MARK: - Terminal text rendering

    @ViewBuilder
    private func terminalText(snap: Snapshot) -> some View {
        let str = buildAttributedStringForSnap(snap: snap)
        Text(str)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            // 行の折返しを禁止し、コンテンツの固有サイズを保つ
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func buildAttributedStringForSnap(snap: Snapshot) -> AttributedString {
        var result = AttributedString()
        // カーソル非表示時は cursorRow に -1 を渡してカーソル描画を抑制する
        let activeCursorRow = snap.cursorVisible ? Int(snap.cursorRow) : -1
        for (rowIdx, row) in snap.rows.enumerated() {
            if rowIdx > 0 {
                result += AttributedString("\n")
            }
            result += buildAttributedString(
                row: row,
                cursorRow: activeCursorRow,
                cursorCol: Int(snap.cursorCol),
                rowIdx: rowIdx
            )
        }
        return result
    }

    private func buildAttributedString(
        row: Row,
        cursorRow: Int,
        cursorCol: Int,
        rowIdx: Int
    ) -> AttributedString {
        var result = AttributedString()
        // colOffset はターミナルセル幅単位で累積する（全角文字=2セル）
        var colOffset = 0
        let isCursorRow = rowIdx == cursorRow

        for span in row.spans {
            let fg = uiColor(from: span.fg)
            let bg = uiColor(from: span.bg)

            // フォントトレイト
            var traits: UIFontDescriptor.SymbolicTraits = []
            if span.flags & FLAG_BOLD != 0 { traits.insert(.traitBold) }
            if span.flags & FLAG_ITALIC != 0 { traits.insert(.traitItalic) }
            let spanFont: UIFont
            if !traits.isEmpty,
               let desc = terminalBaseFont.fontDescriptor.withSymbolicTraits(traits) {
                spanFont = UIFont(descriptor: desc, size: terminalFontSize)
            } else {
                spanFont = terminalBaseFont
            }

            // カーソルがこのスパンのセル範囲内にあるか判定
            let spanCellWidth = span.text.reduce(0) { $0 + cellWidth(of: $1) }
            let spanStart = colOffset
            let spanEnd   = colOffset + spanCellWidth

            if isCursorRow && spanStart <= cursorCol && cursorCol < spanEnd {
                // スパン内にカーソルがある: before / cursorChar / after に分割して描画
                var beforeCells = 0
                var beforeStr   = ""
                var cursorStr   = ""
                var afterStr    = ""
                var pastCursor  = false

                for ch in span.text {
                    let w = cellWidth(of: ch)
                    if pastCursor {
                        afterStr.append(ch)
                    } else if beforeCells + w > cursorCol - spanStart {
                        // このキャラクタがカーソルセル
                        cursorStr.append(ch)
                        pastCursor = true
                    } else {
                        beforeStr.append(ch)
                        beforeCells += w
                    }
                }

                // before 部分（通常スタイル）
                if !beforeStr.isEmpty {
                    var a = AttributedString(beforeStr)
                    a.foregroundColor = fg
                    a.backgroundColor = bg
                    a.font = spanFont
                    if span.flags & FLAG_UNDERLINE != 0 { a.underlineStyle = .single }
                    result += a
                }

                // カーソル文字（反転ハイライト）
                if !cursorStr.isEmpty {
                    var a = AttributedString(cursorStr)
                    a.foregroundColor = bg   // 前景に元背景色
                    a.backgroundColor = fg   // 背景に元前景色
                    a.font = spanFont
                    if span.flags & FLAG_UNDERLINE != 0 { a.underlineStyle = .single }
                    result += a
                }

                // after 部分（通常スタイル）
                if !afterStr.isEmpty {
                    var a = AttributedString(afterStr)
                    a.foregroundColor = fg
                    a.backgroundColor = bg
                    a.font = spanFont
                    if span.flags & FLAG_UNDERLINE != 0 { a.underlineStyle = .single }
                    result += a
                }
            } else {
                // カーソルなし: スパン全体を通常スタイルで描画
                var attr = AttributedString(span.text)
                attr.foregroundColor = fg
                attr.backgroundColor = bg
                attr.font = spanFont
                if span.flags & FLAG_UNDERLINE != 0 { attr.underlineStyle = .single }
                result += attr
            }

            colOffset = spanEnd
        }

        // カーソルが行末より後ろにある場合（シェルプロンプト待受の常見ケース）:
        // スパンループで reverse-highlight されなかったので、ここで末端カーソルを描画する。
        // 履歴行は cursorRow: -1 で呼ばれるため、このガードが自動的にスキップする。
        if isCursorRow && cursorCol >= colOffset {
            // カーソル位置まで空白でパディング（セル単位）
            let padCount = cursorCol - colOffset
            if padCount > 0 {
                var pad = AttributedString(String(repeating: " ", count: padCount))
                pad.font = terminalBaseFont
                result += pad
            }
            // ブロックカーソル: 白背景 + 黒文字
            var cursor = AttributedString(" ")
            cursor.font = terminalBaseFont
            cursor.backgroundColor = Color.white.opacity(0.7)
            cursor.foregroundColor = .black
            result += cursor
        }

        return result
    }

    private func uiColor(from rgba: UInt32) -> Color {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8)  & 0xFF) / 255.0
        let a = Double(rgba         & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    // MARK: - Wide character cell width

    /// 簡易wcwidth。weztermのセル幅と概ね一致すればよい。
    /// 東アジア広字/全角文字は2セル、それ以外は1セルとする。
    private func cellWidth(of ch: Character) -> Int {
        guard let scalar = ch.unicodeScalars.first else { return 1 }
        let v = scalar.value
        switch v {
        case 0x1100...0x115F,   // ハングル字母
             0x2E80...0x303E,   // CJK部首補助〜和文記号
             0x3041...0x33FF,   // ひらがな〜CJK互換
             0x3400...0x4DBF,   // CJK統合漢字拡張A
             0x4E00...0x9FFF,   // CJK統合漢字
             0xA000...0xA4CF,   // 彝文字
             0xAC00...0xD7A3,   // ハングル音節
             0xF900...0xFAFF,   // CJK互換漢字
             0xFE30...0xFE4F,   // CJK互換形
             0xFF00...0xFF60,   // 全角英数・半角カタカナ等
             0xFFE0...0xFFE6,   // 全角記号
             0x1F300...0x1F64F, // 絵文字(顔・記号)
             0x1F900...0x1FAFF, // 絵文字補助
             0x20000...0x2FFFD, // CJK統合漢字拡張B-F
             0x30000...0x3FFFD: // CJK統合漢字拡張G+
            return 2
        default:
            return 1
        }
    }

    // MARK: - Scroll event forwarding

    /// スクロールイベントをペインに送信する。
    /// mouseGrabbed == true なら SGR マウスホイール、false なら矢印キー 3 個。
    /// - Parameters:
    ///   - snap: 現在の Snapshot（mouseGrabbed を参照）
    ///   - up:   true = 上スクロール（指下、過去を見る）
    private func sendScrollEvent(snap: Snapshot, up: Bool) {
        let bytes: [UInt8]
        if snap.mouseGrabbed {
            // SGR マウスホイール（座標はペイン中央: 端の座標は領域外扱いされる場合がある）
            let button: UInt8 = up ? 64 : 65
            let col = max(1, Int(snap.cols) / 2)
            let row = max(1, Int(snap.viewRows) / 2)
            let seq = "\u{1b}[<\(button);\(col);\(row)M"
            bytes = Array(seq.utf8)
        } else {
            // 矢印キー 3 個: ESC [ A (上) / ESC [ B (下)
            let arrow: [UInt8] = up ? [0x1b, 0x5b, 0x41] : [0x1b, 0x5b, 0x42]
            bytes = arrow + arrow + arrow
        }
        store.sendInput(data: Data(bytes))
    }

    // MARK: - Disconnect banner

    private func disconnectBanner(reason: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "wifi.slash")
                Text("Disconnected: \(reason)")
                    .lineLimit(1)
                Spacer()
            }
            .padding(10)
            .background(Color.red.opacity(0.85))
            .foregroundColor(.white)
            .font(.caption)
        }
    }
}
