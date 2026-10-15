import SwiftUI

struct PadRootView: View {
    @StateObject private var listStore = ConnectionListStore()
    @StateObject private var store = ConnectionStore()
    @State private var selectedPane: PaneInfo? = nil
    @State private var connectedAddr: String = ""   // 再接続用

    /// 起動引数 --autoconnect: リスト先頭の接続先へ自動接続
    private var autoConnect: Bool {
        ProcessInfo.processInfo.arguments.contains("--autoconnect")
    }

    /// 起動引数 --attach-pane <id>: 特定ペインへ switchPane して selectedPane に設定（iPad 自動検証用）
    private var attachPaneId: UInt64? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--attach-pane"), idx + 1 < args.count else { return nil }
        return UInt64(args[idx + 1])
    }

    var body: some View {
        NavigationSplitView {
            PadSidebarView(listStore: listStore,
                           store: store,
                           selectedPane: $selectedPane,
                           connectedAddr: $connectedAddr)
        } detail: {
            if let pane = selectedPane {
                TerminalView(store: store, pane: pane)
                    .id(pane.paneId)   // 必須: ペイン固有 @State をビューごとリセット
            } else {
                ContentUnavailableView("ペインを選択",
                                       systemImage: "terminal",
                                       description: Text("サイドバーから接続してペインを選んでください"))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if autoConnect, let first = listStore.connections.first {
                Task {
                    connectedAddr = first.addr
                    await store.makeConnection(addr: first.addr)
                    if let pid = attachPaneId, let target = store.panes.first(where: { $0.paneId == pid }) {
                        await store.switchPane(to: target)
                        selectedPane = target
                    } else if let active = store.panes.first(where: { $0.active }) ?? store.panes.first {
                        await store.switchPane(to: active)
                        selectedPane = active
                    }
                }
            }
        }
    }
}
