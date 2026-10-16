import SwiftUI

// MARK: - TabGroup

/// 同じタブに属するペインのまとまり。ペイン一覧をタブ単位のセクションで表示するために使う。
struct TabGroup: Identifiable, Equatable {
    let tabId: UInt64
    let windowId: UInt64
    /// ListPanes 応答でのタブの並び順（0 始まり）。色分けとタブ番号に使う。
    let tabIndex: UInt32
    /// サーバー側のタブタイトル（未設定なら空文字）。
    let tabTitle: String
    let windowTitle: String
    let panes: [PaneInfo]

    var id: UInt64 { tabId }

    /// 表示用のタブ名。サーバーにタイトルがあればそれ、なければ "Tab N"。
    var displayTitle: String {
        let t = tabTitle.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Tab \(tabIndex + 1)" : t
    }

    /// タブに割り当てる色。
    var color: Color { TabPalette.color(forTabIndex: tabIndex) }

    /// このタブ内のアクティブペイン（無ければ先頭）。分割の既定ターゲットに使う。
    var activePane: PaneInfo? {
        panes.first(where: { $0.active }) ?? panes.first
    }
}

/// 複数ウィンドウがあるときの「新しいタブ」の追加先候補。
struct WindowSummary: Identifiable, Equatable {
    let windowId: UInt64
    let windowTitle: String
    /// ウィンドウ内の最初のタブの workspace（新規タブの workspace に流用する）。
    let workspace: String
    let tabCount: Int

    var id: UInt64 { windowId }

    var displayTitle: String {
        let t = windowTitle.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Window \(windowId)" : t
    }
}

extension Array where Element == PaneInfo {
    /// ペイン一覧をタブ単位にまとめる。順序は ListPanes 応答のタブ順（tabIndex 昇順）。
    func groupedByTab() -> [TabGroup] {
        var order: [UInt64] = []
        var buckets: [UInt64: [PaneInfo]] = [:]
        for pane in self {
            if buckets[pane.tabId] == nil {
                order.append(pane.tabId)
                buckets[pane.tabId] = []
            }
            buckets[pane.tabId]?.append(pane)
        }
        return order.compactMap { tabId in
            guard let panes = buckets[tabId], let first = panes.first else { return nil }
            return TabGroup(tabId: tabId,
                            windowId: first.windowId,
                            tabIndex: first.tabIndex,
                            tabTitle: first.tabTitle,
                            windowTitle: first.windowTitle,
                            panes: panes)
        }
        .sorted { $0.tabIndex < $1.tabIndex }
    }

    /// ウィンドウの一覧（出現順）。
    func windowSummaries() -> [WindowSummary] {
        var order: [UInt64] = []
        var first: [UInt64: PaneInfo] = [:]
        var tabs: [UInt64: Set<UInt64>] = [:]
        for pane in self {
            if first[pane.windowId] == nil {
                order.append(pane.windowId)
                first[pane.windowId] = pane
            }
            tabs[pane.windowId, default: []].insert(pane.tabId)
        }
        return order.compactMap { wid in
            guard let p = first[wid] else { return nil }
            return WindowSummary(windowId: wid,
                                 windowTitle: p.windowTitle,
                                 workspace: p.workspace,
                                 tabCount: tabs[wid]?.count ?? 0)
        }
    }

    /// 指定ペインが属するタブの色。一覧に無ければ secondary。
    func tabColor(for pane: PaneInfo) -> Color {
        if let match = self.first(where: { $0.tabId == pane.tabId }) {
            return TabPalette.color(forTabIndex: match.tabIndex)
        }
        return TabPalette.color(forTabIndex: pane.tabIndex)
    }
}

// MARK: - TabPalette

/// タブの色分けパレット。タブの並び順（tabIndex）で循環的に割り当てる。
/// ダーク背景の端末 UI で判別しやすいよう、彩度高めの色を並べている。
enum TabPalette {
    static let colors: [Color] = [
        .orange,
        .cyan,
        .green,
        .pink,
        .yellow,
        .purple,
        .mint,
        .red,
        .indigo,
        .brown,
    ]

    static func color(forTabIndex index: UInt32) -> Color {
        colors[Int(index) % colors.count]
    }
}

// MARK: - TabColorBar

/// ペイン行の左端に置く、所属タブ色の縦バー。
struct TabColorBar: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 4)
            .padding(.vertical, 2)
    }
}

/// タブセクションのヘッダー（色ドット + タブ名 + ペイン数）。
struct TabSectionHeader: View {
    let group: TabGroup
    /// 複数ウィンドウがあるときだけウィンドウ名を添える
    let showWindow: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(group.color)
                .frame(width: 10, height: 10)
            Text(group.displayTitle)
                .foregroundColor(group.color)
            Text("· \(group.panes.count) pane\(group.panes.count == 1 ? "" : "s")")
                .foregroundColor(.secondary)
            if showWindow {
                Text("· \(group.windowTitle.isEmpty ? "Window \(group.windowId)" : group.windowTitle)")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .textCase(nil)
    }
}

// MARK: - Split / new-tab menu items

/// 「ペインを分割」「新しいタブ」のメニュー項目。
/// PaneListView / PadSidebarView / TerminalView で共通に使う。
struct PaneCreateMenuItems: View {
    @ObservedObject var store: ConnectionStore
    /// 分割対象ペイン（nil なら分割項目を出さない）
    let splitTarget: PaneInfo?
    /// 「新しいタブ」をこのペインと同じウィンドウに作る。
    /// nil のときは全ウィンドウを候補に出す（ウィンドウが 1 つならそれを直接使う）。
    let sameWindowAs: PaneInfo?
    /// 作成に成功したら新ペインを渡す（呼び出し側で attach / 画面遷移する）
    let onCreated: (PaneInfo) -> Void

    var body: some View {
        if let target = splitTarget {
            Button {
                Task {
                    if let p = await store.splitPane(target, direction: .horizontal) { onCreated(p) }
                }
            } label: {
                Label("右に分割", systemImage: "rectangle.split.2x1")
            }
            Button {
                Task {
                    if let p = await store.splitPane(target, direction: .vertical) { onCreated(p) }
                }
            } label: {
                Label("下に分割", systemImage: "rectangle.split.1x2")
            }
            Divider()
        }
        newTabItems
    }

    @ViewBuilder
    private var newTabItems: some View {
        let windows = store.panes.windowSummaries()
        if let anchor = sameWindowAs,
           let win = windows.first(where: { $0.windowId == anchor.windowId }) {
            newTabButton(window: win, label: "新しいタブ")
        } else if windows.count <= 1 {
            // ウィンドウが 1 つ（または 0 = 新規ウィンドウ）
            newTabButton(window: windows.first, label: "新しいタブ")
        } else {
            Menu {
                ForEach(windows) { win in
                    newTabButton(window: win, label: "\(win.displayTitle)（\(win.tabCount) tabs）")
                }
                Divider()
                newTabButton(window: nil, label: "新しいウィンドウに作る")
            } label: {
                Label("新しいタブ…", systemImage: "plus.rectangle.on.rectangle")
            }
        }
    }

    private func newTabButton(window: WindowSummary?, label: String) -> some View {
        Button {
            Task {
                if let p = await store.newTab(windowId: window?.windowId,
                                              workspace: window?.workspace ?? "default") {
                    onCreated(p)
                }
            }
        } label: {
            Label(label, systemImage: "plus.rectangle.on.rectangle")
        }
    }
}
