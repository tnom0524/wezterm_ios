import SwiftUI

// MARK: - ConnectionRowLabel

/// 接続先の行ラベル（名前 + アドレス）。ConnectView と PadSidebarView の両方で共用。
struct ConnectionRowLabel: View {
    let conn: SavedConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conn.name)
                .font(.headline)
                .foregroundColor(.primary)
            Text(conn.addr)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - PadSidebarView

struct PadSidebarView: View {
    @ObservedObject var listStore: ConnectionListStore
    @ObservedObject var store: ConnectionStore

    @Binding var selectedPane: PaneInfo?
    @Binding var connectedAddr: String

    @State private var connectingId: UUID? = nil
    @State private var showAddSheet = false
    @State private var editingConnection: SavedConnection? = nil

    var body: some View {
        List {
            // MARK: 接続先セクション
            Section("接続先") {
                ForEach(listStore.connections) { conn in
                    connectionRow(conn)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let idx = listStore.connections.firstIndex(of: conn) {
                                    listStore.delete(at: IndexSet(integer: idx))
                                }
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                editingConnection = conn
                            } label: {
                                Label("編集", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                }
            }

            // MARK: ペインセクション（接続中 or 切断直後に表示）
            // 注意: サーバー切断時は handleDisconnected が isConnected=false にするため、
            // disconnectReason も条件に含めないと再接続 UI が表示されない
            if let reason = store.disconnectReason {
                Section("ペイン") {
                    // 切断バナー: 再接続ボタンをセクション内に表示
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("切断されました")
                                .font(.subheadline.bold())
                            Text(reason)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("再接続") {
                            Task { await store.reconnect(addr: connectedAddr) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            } else if store.isConnected {
                // タブごとのセクション（色分け）。新しいタブはツールバーの「＋」から。
                let multiWindow = store.panes.windowSummaries().count > 1
                ForEach(store.panes.groupedByTab()) { group in
                    Section {
                        ForEach(group.panes, id: \.paneId) { pane in
                            paneRow(pane, color: group.color)
                        }
                    } header: {
                        HStack {
                            TabSectionHeader(group: group, showWindow: multiWindow)
                            Spacer()
                            // このタブのアクティブペインを分割 / 同じウィンドウに新しいタブ
                            Menu {
                                PaneCreateMenuItems(store: store,
                                                    splitTarget: group.activePane,
                                                    sameWindowAs: group.activePane,
                                                    onCreated: openCreatedPane)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.body)
                                    .foregroundColor(group.color)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("WezTerm Mobile")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            if store.isConnected {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Refresh") {
                        Task { await store.refreshPanes() }
                    }
                }
                // 新しいタブ（ウィンドウが複数あれば追加先を選ぶ）。右端の「＋」は接続先追加。
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        PaneCreateMenuItems(store: store,
                                            splitTarget: nil,
                                            sameWindowAs: nil,
                                            onCreated: openCreatedPane)
                    } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                }
            }
        }
        .alert("Connection Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") {
                store.errorMessage = nil
                connectingId = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(isPresented: $showAddSheet) {
            ConnectionFormSheet(mode: .add) { newConn in
                listStore.add(newConn)
            }
        }
        .sheet(item: $editingConnection) { conn in
            ConnectionFormSheet(mode: .edit(conn)) { updated in
                listStore.update(updated)
            }
        }
    }

    // MARK: - 接続先行

    @ViewBuilder
    private func connectionRow(_ conn: SavedConnection) -> some View {
        let isConnectedToThis = store.isConnected && conn.addr == connectedAddr

        Button {
            guard !store.isConnecting else { return }
            if isConnectedToThis {
                // 接続済みの場合はなにもしない（コンテキストメニューから切断可能）
            } else {
                connectingId = conn.id
                connectedAddr = conn.addr
                Task { await store.makeConnection(addr: conn.addr) }
            }
        } label: {
            HStack {
                ConnectionRowLabel(conn: conn)
                Spacer()
                if connectingId == conn.id && store.isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if isConnectedToThis {
                    // 接続済みインジケータ（緑の点）
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isConnecting && connectingId != conn.id)
        .contextMenu {
            if isConnectedToThis {
                Button(role: .destructive) {
                    selectedPane = nil
                    store.disconnect()
                    connectedAddr = ""
                    connectingId = nil
                } label: {
                    Label("切断", systemImage: "xmark.circle")
                }
            }
        }
    }

    // MARK: - ペイン作成

    /// 新規作成したペインへ attach して詳細ビューを切り替える。
    private func openCreatedPane(_ pane: PaneInfo) {
        Task {
            await store.switchPane(to: pane)
            selectedPane = pane
        }
    }

    // MARK: - ペイン行

    @ViewBuilder
    private func paneRow(_ pane: PaneInfo, color: Color) -> some View {
        Button {
            Task {
                await store.switchPane(to: pane)
                selectedPane = pane
            }
        } label: {
            HStack(spacing: 10) {
                TabColorBar(color: color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if pane.active {
                            Image(systemName: "circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 8))
                        }
                        Text("Pane \(pane.paneId)")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    Text(pane.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("\(pane.cols)x\(pane.rows)  ws:\(pane.workspace)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                if selectedPane?.paneId == pane.paneId {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.caption.bold())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 長押し / 右クリック: このペインを分割 / 同じウィンドウに新しいタブ
        .contextMenu {
            PaneCreateMenuItems(store: store,
                                splitTarget: pane,
                                sameWindowAs: pane,
                                onCreated: openCreatedPane)
        }
        // 右スワイプ: 分割のショートカット
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task {
                    if let p = await store.splitPane(pane, direction: .horizontal) { openCreatedPane(p) }
                }
            } label: {
                Label("右に分割", systemImage: "rectangle.split.2x1")
            }
            .tint(color)
            Button {
                Task {
                    if let p = await store.splitPane(pane, direction: .vertical) { openCreatedPane(p) }
                }
            } label: {
                Label("下に分割", systemImage: "rectangle.split.1x2")
            }
            .tint(color.opacity(0.7))
        }
    }
}
