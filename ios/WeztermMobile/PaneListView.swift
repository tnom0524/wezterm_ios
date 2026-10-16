import SwiftUI

struct PaneListView: View {
    @ObservedObject var store: ConnectionStore
    let addr: String

    @State private var selectedPane: PaneInfo? = nil

    /// 起動引数 --autoattach で active pane に自動 attach する
    private var autoAttach: Bool {
        ProcessInfo.processInfo.arguments.contains("--autoattach")
    }

    /// 起動引数 --attach-pane <id> で特定ペインに自動 attach する（自動テスト用）
    private var attachPaneId: UInt64? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--attach-pane"), idx + 1 < args.count else { return nil }
        return UInt64(args[idx + 1])
    }

    var body: some View {
        Group {
            if let reason = store.disconnectReason {
                disconnectedView(reason: reason)
            } else {
                paneList
            }
        }
        .navigationTitle("Panes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Refresh") {
                    Task { await store.refreshPanes() }
                }
            }
            // 新しいタブ / 分割（分割はタブセクション・ペイン行のメニューから）
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    PaneCreateMenuItems(store: store,
                                        splitTarget: nil,
                                        sameWindowAs: nil,
                                        onCreated: openCreatedPane)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.isConnected)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Disconnect") {
                    store.disconnect()
                }
                .foregroundColor(.red)
            }
        }
        .onAppear {
            Task {
                await store.refreshPanes()
                if let created = await store.runLaunchArgumentPaneCreation() {
                    openCreatedPane(created)
                } else if let pid = attachPaneId, let target = store.panes.first(where: { $0.paneId == pid }) {
                    await store.attach(pane: target)
                    selectedPane = target
                } else if autoAttach, let active = store.panes.first(where: { $0.active }) ?? store.panes.first {
                    await store.attach(pane: active)
                    selectedPane = active
                }
            }
        }
        .navigationDestination(item: $selectedPane) { pane in
            TerminalView(store: store, pane: pane, onPaneCreated: openCreatedPane)
                .id(pane.paneId)   // ペイン固有 @State をビューごとリセット
        }
    }

    /// 新規作成したペインへ attach して画面を切り替える。
    private func openCreatedPane(_ pane: PaneInfo) {
        Task {
            await store.switchPane(to: pane)
            selectedPane = pane
        }
    }

    private var paneList: some View {
        let groups = store.panes.groupedByTab()
        let multiWindow = store.panes.windowSummaries().count > 1
        return List {
            ForEach(groups) { group in
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

    @ViewBuilder
    private func paneRow(_ pane: PaneInfo, color: Color) -> some View {
        Button(action: {
            Task {
                await store.attach(pane: pane)
                selectedPane = pane
            }
        }) {
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
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 長押し: このペインを分割 / 同じウィンドウに新しいタブ
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

    private func disconnectedView(reason: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Disconnected")
                .font(.title2.bold())
            Text(reason)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Reconnect") {
                Task { await store.reconnect(addr: addr) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
