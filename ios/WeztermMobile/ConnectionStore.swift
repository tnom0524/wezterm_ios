import Foundation
import SwiftUI

// MARK: - ClientDelegate implementation

/// Rust エンジンスレッドからコールバックを受け取り、MainActor へ hop して @Published を更新する。
final class ConnectionStoreDelegate: ClientDelegate, @unchecked Sendable {
    weak var store: ConnectionStore?

    func onSnapshot(paneId: UInt64, snap: Snapshot) {
        let s = store
        Task { @MainActor in
            s?.handleSnapshot(paneId: paneId, snap: snap)
        }
    }

    func onDisconnected(reason: String) {
        let s = store
        Task { @MainActor in
            s?.handleDisconnected(reason: reason)
        }
    }
}

// MARK: - ConnectionStore

@MainActor
final class ConnectionStore: ObservableObject {

    // MARK: Published state

    @Published var panes: [PaneInfo] = []
    @Published var snapshot: Snapshot? = nil
    @Published var attachedPaneId: UInt64? = nil
    /// attach 中のペインが属するタブ。閲覧を終えるときに寸法復元（restoreSizes）の鍵に使う。
    /// attachedPaneId が nil（切替中・バックグラウンド中）でも、復元が済むまでは保持する。
    private(set) var attachedTabId: UInt64? = nil
    /// paneViewDisappeared() が起動した復元タスク。直後の attach はこれを待ってから進む
    /// （復元 → attach の順でエンジンに届くことを保証する）。
    private var pendingRestore: Task<Void, Never>? = nil
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String? = nil
    @Published var disconnectReason: String? = nil

    // MARK: Scrollback state

    /// StableRowIndex → Row キャッシュ（viewport行 + 取得済み履歴行）
    @Published var rowCache: [Int64: Row] = [:]
    /// ライブビューポートの先頭 StableRowIndex（最新 Snapshot から）
    @Published var physicalTop: Int64 = 0
    /// スクロールバック内で取得可能な最古行の StableRowIndex
    @Published var scrollbackTop: Int64 = 0
    /// 現在ロード済みの履歴の先頭 StableRowIndex（ここより古い行はまだ未取得）
    @Published var loadedHistoryTop: Int64 = 0

    // MARK: Render throttle state

    /// 次回描画のために保留中のスナップショット
    private var pendingSnapshot: Snapshot? = nil
    /// 最後に snapshot を公開した時刻
    private var lastRenderAt: Date? = nil
    /// スロットル用のトレイリングレンダータスク
    private var renderTask: Task<Void, Never>? = nil
    /// true の間は snapshot 公開を凍結し pendingSnapshot に保留する（スクロール中）
    private(set) var renderFrozen: Bool = false
    /// 最後にユーザー操作（キー入力・ペースト）があった時刻
    private(set) var lastUserActionAt: Date = Date.distantPast

    // MARK: Prefetch state

    /// アグレッシブ先読み実行中フラグ（二重起動を防ぐ）
    private var isPrefetching: Bool = false

    // MARK: Private state

    private var client: MuxClient? = nil
    private let delegate = ConnectionStoreDelegate()

    // MARK: Init

    init() {
        delegate.store = self
        // 強制終了ではなく通常終了（タスクスイッチャーからのスワイプ等）なら、
        // 同期的に寸法を戻してから死ぬ。Rust 側の RPC 1 往復分だけメインスレッドを塞ぐ。
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreSizesSynchronously()
            }
        }
    }

    // MARK: - Public API

    func makeConnection(addr: String) async {
        guard !isConnecting && !isConnected else { return }
        isConnecting = true
        errorMessage = nil
        disconnectReason = nil

        let d = delegate
        let addrCopy = addr
        let result = await Task.detached(priority: .userInitiated) {
            return Result { () throws -> MuxClient in
                try rustConnect(addr: addrCopy, delegate: d)
            }
        }.value

        isConnecting = false
        switch result {
        case .success(let c):
            client = c
            isConnected = true
            await refreshPanes()
        case .failure(let e):
            errorMessage = e.localizedDescription
        }
    }

    func refreshPanes() async {
        guard let c = client else { return }
        let result = await Task.detached(priority: .userInitiated) {
            return Result { try c.listPanes() }
        }.value
        switch result {
        case .success(let list):
            panes = list
        case .failure(let e):
            errorMessage = e.localizedDescription
        }
    }

    func attach(pane: PaneInfo) async {
        guard let c = client else { return }
        // 直前まで見ていたタブの寸法をまだ戻していなければ、先に戻す
        // （Rust 側は attach 時に「控えが無ければ控える」ので、戻してから attach する順序が重要）。
        await pendingRestore?.value
        pendingRestore = nil
        await restoreSizesIfNeeded()
        let pid = pane.paneId
        let cols = pane.cols
        let rows = pane.rows
        let result = await Task.detached(priority: .userInitiated) {
            return Result { try c.attach(paneId: pid, cols: cols, rows: rows) }
        }.value
        switch result {
        case .success:
            attachedPaneId = pid
            attachedTabId = pane.tabId
        case .failure(let e):
            errorMessage = e.localizedDescription
        }
    }

    // MARK: - Pane size restore

    /// ターミナル画面を閉じた（ペイン一覧へ戻った）ときに呼ぶ。
    /// そのペインに attach したままなら購読対象から外し、タブの寸法を元に戻す。
    /// 別ペインへ切替済み（attachedPaneId が別の値）の場合は何もしない:
    /// 切替時の復元は attach() が先に済ませている。
    func paneViewDisappeared(_ pane: PaneInfo) {
        guard attachedPaneId == pane.paneId else { return }
        attachedPaneId = nil
        pendingRestore = Task { await restoreSizesIfNeeded() }
    }

    /// バックグラウンド遷移時: attach は維持したまま寸法だけ Mac 側の値に戻す。
    /// 復帰後は TerminalView が自分の寸法を再送する（Rust 側がその直前に再び控える）。
    func restoreSizesForBackground() async {
        guard let c = client, let tabId = attachedTabId else { return }
        await Self.callRestore(c, tabId: tabId)
    }

    /// attachedTabId が残っていれば寸法を復元して忘れる。
    private func restoreSizesIfNeeded() async {
        guard let c = client, let tabId = attachedTabId else { return }
        attachedTabId = nil
        await Self.callRestore(c, tabId: tabId)
    }

    private static func callRestore(_ c: MuxClient, tabId: UInt64) async {
        _ = await Task.detached(priority: .userInitiated) {
            Result { try c.restoreSizes(tabId: tabId) }
        }.value
    }

    /// アプリ終了通知用: メインスレッド上で同期的に復元する（await できないため）。
    private func restoreSizesSynchronously() {
        guard let c = client, let tabId = attachedTabId else { return }
        attachedTabId = nil
        try? c.restoreSizes(tabId: tabId)
    }

    // MARK: - Pane creation

    /// 新しいタブ（＝新規ペイン）を作る。windowId が nil なら新規ウィンドウ。
    /// 成功したら一覧を更新し、新ペインの PaneInfo を返す（呼び出し側で attach する）。
    func newTab(windowId: UInt64?, workspace: String) async -> PaneInfo? {
        guard let c = client else { return nil }
        let (cols, rows) = preferredSpawnSize()
        let result = await Task.detached(priority: .userInitiated) {
            return Result { try c.spawn(windowId: windowId, workspace: workspace, cols: cols, rows: rows) }
        }.value
        return await finishCreate(result)
    }

    /// 既存ペインを分割して新しいペインを作る。
    /// 成功したら一覧を更新し、新ペインの PaneInfo を返す（呼び出し側で attach する）。
    func splitPane(_ pane: PaneInfo, direction: SplitDirection) async -> PaneInfo? {
        guard let c = client else { return nil }
        let pid = pane.paneId
        let result = await Task.detached(priority: .userInitiated) {
            return Result { try c.splitPane(paneId: pid, direction: direction) }
        }.value
        return await finishCreate(result)
    }

    /// 起動引数による自動ペイン作成（自動テスト用。既存の --autoattach / --attach-pane と同じ仕組み）。
    ///   --split-pane <paneId> <right|down>  指定ペインを分割
    ///   --new-tab                           最初のウィンドウに新しいタブを作る
    /// 接続済みで一覧取得後に呼ぶ。作成した新ペインを返す（引数が無ければ nil）。
    func runLaunchArgumentPaneCreation() async -> PaneInfo? {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--split-pane"), idx + 2 < args.count,
           let pid = UInt64(args[idx + 1]),
           let target = panes.first(where: { $0.paneId == pid }) {
            let direction: SplitDirection = args[idx + 2] == "down" ? .vertical : .horizontal
            return await splitPane(target, direction: direction)
        }
        if args.contains("--new-tab") {
            let win = panes.windowSummaries().first
            return await newTab(windowId: win?.windowId, workspace: win?.workspace ?? "default")
        }
        return nil
    }

    /// spawn / split の結果を受けてペイン一覧を再取得し、新ペインを探して返す。
    private func finishCreate(_ result: Result<SpawnInfo, Error>) async -> PaneInfo? {
        switch result {
        case .success(let info):
            await refreshPanes()
            if let found = panes.first(where: { $0.paneId == info.paneId }) {
                return found
            }
            errorMessage = "新しいペイン (id=\(info.paneId)) が一覧に見つかりませんでした"
            return nil
        case .failure(let e):
            errorMessage = e.localizedDescription
            return nil
        }
    }

    /// 新規タブの初期サイズ。attach 中のペインがあればその画面サイズ、無ければ 80x24。
    private func preferredSpawnSize() -> (UInt32, UInt32) {
        if let snap = snapshot, snap.cols > 0, snap.viewRows > 0 {
            return (snap.cols, snap.viewRows)
        }
        return (80, 24)
    }

    /// ペインをリサイズする。結果は次の Snapshot に新寸法で反映される。
    func resize(paneId: UInt64, tabId: UInt64, cols: UInt32, rows: UInt32) {
        guard let c = client else { return }
        Task.detached(priority: .userInitiated) {
            try? c.resize(paneId: paneId, tabId: tabId, cols: cols, rows: rows)
        }
    }

    func sendInput(data: Data) {
        guard let c = client, let pid = attachedPaneId else { return }
        lastUserActionAt = Date()
        Task.detached(priority: .userInitiated) {
            try? c.sendInput(paneId: pid, data: data)
        }
    }

    /// クリップボードの文字列をブラケットペーストとしてペインへ送る。
    func sendPaste(text: String) {
        guard let c = client, let pid = attachedPaneId else { return }
        lastUserActionAt = Date()
        Task.detached(priority: .userInitiated) {
            try? c.sendPaste(paneId: pid, text: text)
        }
    }

    func disconnect() {
        // Rust 側の disconnect() が、未復元のタブ寸法を全部戻してからソケットを閉じる。
        client?.disconnect()
        client = nil
        isConnected = false
        panes = []
        snapshot = nil
        attachedPaneId = nil
        attachedTabId = nil
        rowCache = [:]
        physicalTop = 0
        scrollbackTop = 0
        loadedHistoryTop = 0
        renderTask?.cancel()
        renderTask = nil
        pendingSnapshot = nil
        // スクロール中に切断された場合に凍結が残らないようリセットする
        // （凍結が残ると再接続後の snapshot が永遠に公開されない）
        renderFrozen = false
        lastRenderAt = nil
    }

    /// スクロールバック履歴行を取得してキャッシュに格納する。
    /// first_row から最大 chunkSize 行、scrollbackTop より前は取得しない。
    func fetchHistory(upTo targetRow: Int64, chunkSize: Int64 = 100) async {
        guard let c = client, let pid = attachedPaneId else { return }
        // すでにロード済みの範囲より古い行がターゲット
        let fetchEnd = loadedHistoryTop
        let fetchStart = max(scrollbackTop, fetchEnd - chunkSize)
        guard fetchStart < fetchEnd else { return }

        let count = UInt32(fetchEnd - fetchStart)
        let firstRow = fetchStart
        let result = await Task.detached(priority: .userInitiated) {
            return Result { try c.fetchLines(paneId: pid, firstRow: firstRow, count: count) }
        }.value

        switch result {
        case .success(let rows):
            for (i, row) in rows.enumerated() {
                let idx = firstRow + Int64(i)
                rowCache[idx] = row
            }
            loadedHistoryTop = fetchStart
        case .failure(let e):
            errorMessage = e.localizedDescription
        }
    }

    /// loadedHistoryTop より前の行を最大 chunk 行まとめてロードする。
    /// scrollbackTop に達して新規ロードがなければ false を返す。
    func fetchOlderHistory(chunk: Int = 500) async -> Bool {
        guard loadedHistoryTop > scrollbackTop else { return false }
        let before = loadedHistoryTop
        var remaining = chunk
        while remaining > 0 && loadedHistoryTop > scrollbackTop {
            let batchSize = min(Int64(remaining), 100)
            let prevTop = loadedHistoryTop
            await fetchHistory(upTo: loadedHistoryTop, chunkSize: batchSize)
            // 進捗なし（エラー等）なら無限ループを防ぐ
            if loadedHistoryTop == prevTop { break }
            remaining -= Int(prevTop - loadedHistoryTop)
        }
        return loadedHistoryTop < before
    }

    /// 初回スナップショット到着後に履歴を積極的に先読みする。
    /// target 行分（physicalTop - loadedHistoryTop）確保するか scrollbackTop に達するまで繰り返す。
    func prefetchHistory(target: Int = 500) async {
        guard !isPrefetching else { return }
        isPrefetching = true
        defer { isPrefetching = false }

        while physicalTop - loadedHistoryTop < Int64(target)
                && loadedHistoryTop > scrollbackTop {
            let prevTop = loadedHistoryTop
            await fetchHistory(upTo: loadedHistoryTop)
            // 進捗なしならループを抜ける
            if loadedHistoryTop == prevTop { break }
        }
    }

    func reconnect(addr: String) async {
        disconnectReason = nil
        await makeConnection(addr: addr)
    }

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
        // 旧タブの寸法復元は attach() の中で（attachedTabId を手がかりに）行う
        await attach(pane: pane)
    }

    // MARK: - Render freeze control

    /// スクロール操作中の描画凍結を切り替える。
    /// frozen → false に戻ったとき、保留スナップショットをただちに公開する。
    func setRenderFrozen(_ frozen: Bool) {
        guard renderFrozen != frozen else { return }
        renderFrozen = frozen
        if !frozen, let pending = pendingSnapshot {
            publishSnapshot(pending, at: Date())
        }
    }

    // MARK: - Delegate handlers (called on MainActor)

    func handleSnapshot(paneId: UInt64, snap: Snapshot) {
        guard paneId == attachedPaneId else { return }

        // ── ブックキーピング（常に即時更新。描画遅延とは独立） ──
        // physicalTop / scrollbackTop / loadedHistoryTop / rowCache は
        // 描画を保留中でも常に最新値に保つ。こうすることで prefetch や
        // 履歴インデックス計算が遅延なく正確に動作する。
        let isFirstSnapshot = snapshot == nil
        physicalTop = snap.physicalTop
        scrollbackTop = snap.scrollbackTop
        // 初回 attach 時にのみ loadedHistoryTop を physicalTop に設定する
        // （履歴閲覧中は変えない: 古い行はそのままキャッシュに残す）
        if loadedHistoryTop == 0 || loadedHistoryTop > snap.physicalTop {
            loadedHistoryTop = snap.physicalTop
        }
        // viewport 行をキャッシュに格納（StableRowIndex = physicalTop + i）
        for (i, row) in snap.rows.enumerated() {
            rowCache[snap.physicalTop + Int64(i)] = row
        }

        // ── 描画スロットル ──
        let now = Date()
        let sinceAction = now.timeIntervalSince(lastUserActionAt)
        let sinceRender = lastRenderAt.map { now.timeIntervalSince($0) } ?? Double.infinity

        if renderFrozen {
            // 指がスクリーンに触れている間はスナップショットを保留
            pendingSnapshot = snap
        } else if sinceAction < 1.0 || sinceRender >= 0.25 {
            // ユーザー操作後 1 秒以内 or 前回描画から 0.25s 以上 → 即時描画
            publishSnapshot(snap, at: now)
        } else {
            // スロットル中: 前回描画から 0.25s が経つまで保留してトレイリング描画
            pendingSnapshot = snap
            scheduleTrailingRender(after: 0.25 - sinceRender)
        }

        // 初回スナップショット到着時にアグレッシブ先読みを開始
        if isFirstSnapshot {
            Task { await prefetchHistory() }
        }
    }

    func handleDisconnected(reason: String) {
        disconnectReason = reason
        isConnected = false
        client = nil
        attachedTabId = nil   // 接続が死んだので戻しようがない
    }

    // MARK: - Private render helpers

    private func publishSnapshot(_ snap: Snapshot, at time: Date) {
        renderTask?.cancel()
        renderTask = nil
        snapshot = snap
        lastRenderAt = time
        pendingSnapshot = nil
    }

    private func scheduleTrailingRender(after delay: TimeInterval) {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let ns = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // 凍結中は公開しない（保留のまま。setRenderFrozen(false) が flush する）
                if !self.renderFrozen, let pending = self.pendingSnapshot {
                    self.publishSnapshot(pending, at: Date())
                }
            }
        }
    }
}
