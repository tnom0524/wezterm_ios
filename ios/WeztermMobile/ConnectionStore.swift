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

    // MARK: Private state

    private var client: MuxClient? = nil
    private let delegate = ConnectionStoreDelegate()

    // MARK: Init

    init() {
        delegate.store = self
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
        let pid = pane.paneId
        let cols = pane.cols
        let rows = pane.rows
        let result = await Task.detached(priority: .userInitiated) {
            return Result { try c.attach(paneId: pid, cols: cols, rows: rows) }
        }.value
        switch result {
        case .success:
            attachedPaneId = pid
        case .failure(let e):
            errorMessage = e.localizedDescription
        }
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
        Task.detached(priority: .userInitiated) {
            try? c.sendInput(paneId: pid, data: data)
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        isConnected = false
        panes = []
        snapshot = nil
        attachedPaneId = nil
        rowCache = [:]
        physicalTop = 0
        scrollbackTop = 0
        loadedHistoryTop = 0
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

    func reconnect(addr: String) async {
        disconnectReason = nil
        await makeConnection(addr: addr)
    }

    // MARK: - Delegate handlers (called on MainActor)

    func handleSnapshot(paneId: UInt64, snap: Snapshot) {
        if paneId == attachedPaneId {
            snapshot = snap
            physicalTop = snap.physicalTop
            scrollbackTop = snap.scrollbackTop
            // 初回 attach 時にのみ loadedHistoryTop を physicalTop に設定する
            // （履歴閲覧中は変えない: 古い行はそのままキャッシュに残す）
            if loadedHistoryTop == 0 || loadedHistoryTop > snap.physicalTop {
                loadedHistoryTop = snap.physicalTop
            }
            // viewport 行をキャッシュに格納（StableRowIndex = physicalTop + i）
            for (i, row) in snap.rows.enumerated() {
                let idx = snap.physicalTop + Int64(i)
                rowCache[idx] = row
            }
        }
    }

    func handleDisconnected(reason: String) {
        disconnectReason = reason
        isConnected = false
        client = nil
    }
}
