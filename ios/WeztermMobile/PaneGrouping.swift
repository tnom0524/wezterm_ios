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

    /// 表示用のタブ名。サーバーの tabTitle → アクティブペインの cwd から求めたプロジェクト名 → "Tab N" の順。
    /// MacBook 側 wezterm の format-tab-title と同じ決め方（~/.config/wezterm/wezterm.lua の project_from_cwd）。
    var displayTitle: String {
        let t = tabTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        if let p = activePane, let name = ProjectName.fromWorkingDir(p.workingDir) {
            return name
        }
        return "Tab \(tabIndex + 1)"
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

// MARK: - ProjectName

/// ペインの cwd からタブ表示用のプロジェクト名を求める。
///
/// MacBook 側 wezterm の `project_from_cwd`（~/.config/wezterm/wezterm.lua）の移植。どちらかを変えたらもう一方も合わせること。
///   /Users/me/work/01-client/monorepo/foo        → foo       (NN-分類 を飛ばし、入れ物も飛ばす。containers に "monorepo" がある場合)
///   /Users/me/work/00-personal/05-wezterm_ios    → 05-wezterm_ios
///   /home/ubuntu/workspace/my-project            → my-project
///   /home/ubuntu/workspace/X/.worktrees/wt1      → X⎇wt1
///   /Users/me                                    → ~
enum ProjectName {
    /// 「入れ物」フォルダ: この直下ではなく一段下をプロジェクトとみなす。
    /// 既定は空。自分の環境に入れ物フォルダがあればその名前をここに足す（例: ["monorepo"]）。
    static let containers: Set<String> = []

    /// `file://host/path` 形式の URL 文字列（PaneInfo.workingDir）から。空や解釈不能なら nil。
    static func fromWorkingDir(_ urlString: String) -> String? {
        guard !urlString.isEmpty else { return nil }
        // URL(string:) はホスト付き file URL でも path を返す。パーセントデコードも済む。
        let path: String
        if let url = URL(string: urlString), !url.path.isEmpty {
            path = url.path
        } else if let r = urlString.range(of: "://"), let slash = urlString[r.upperBound...].firstIndex(of: "/") {
            path = String(urlString[slash...]).removingPercentEncoding ?? String(urlString[slash...])
        } else {
            return nil
        }
        return fromPath(path)
    }

    /// 絶対パスから。
    static func fromPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let comps = path.split(separator: "/").map(String.init)
        // ホーム配下の作業ルートを剥がす
        var rest: [String]
        if comps.count >= 2, comps[0] == "Users" || comps[0] == "home" {
            rest = Array(comps.dropFirst(2))
        } else if comps.first == "root" {
            rest = Array(comps.dropFirst(1))
        } else {
            // ホーム外: 末尾のフォルダ名だけ
            return comps.last
        }
        if let f = rest.first, f == "work" || f == "workspace" {
            rest.removeFirst()
        }
        if let f = rest.first, isCategory(f) {
            // "NN-名前" は分類フォルダ。その直下に居るときだけそれ自体を出す
            if rest.count == 1 { return f }
            rest.removeFirst()
        }
        if let f = rest.first, containers.contains(f), rest.count >= 2 {
            rest.removeFirst()
        }
        guard let proj = rest.first else { return "~" }
        // git worktree の中なら "proj⎇worktree名"
        if let i = rest.dropFirst().firstIndex(of: ".worktrees"), i + 1 < rest.count {
            return proj + "⎇" + rest[i + 1]
        }
        return proj
    }

    /// "NN-..." （数字 2 桁 + ハイフン）か。
    private static func isCategory(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return u.count >= 3 && u[0] >= 48 && u[0] <= 57 && u[1] >= 48 && u[1] <= 57 && u[2] == 45
    }
}

// MARK: - TabPalette

/// タブの色分けパレット。タブの並び順（tabIndex）で循環的に割り当てる。
///
/// 色は MacBook 側 wezterm の設定（~/.config/wezterm/wezterm.lua の DOMAIN_STYLE / FALLBACK_COLORS）と同じ値。
/// wezterm 側はマシン（mux ドメイン）ごとに固定色を割り当てていて、こちらはタブ順で割り当てる、という違いはあるが、
/// 使う色の集合を揃えて iPhone と MacBook で色の印象を共通にしている（2026-10-17）。
/// 並びは wezterm 側のマシン 1〜5 → 予備色 の順で、local 用の灰色だけ最後に回している
/// （1 番目のタブが灰色だと見分けにくいため）。どちらかの色を変えたらもう一方も合わせること。
enum TabPalette {
    static let colors: [Color] = [
        Color(hex: 0xC084FC), // 紫   (wezterm: マシン 1)
        Color(hex: 0x22D3EE), // シアン (wezterm: マシン 2)
        Color(hex: 0x4ADE80), // 緑   (wezterm: マシン 3)
        Color(hex: 0xF472B6), // ピンク (wezterm: マシン 4)
        Color(hex: 0xFACC15), // 黄   (wezterm: マシン 5)
        Color(hex: 0xFB923C), // 橙   (wezterm: 予備 1)
        Color(hex: 0x2DD4BF), // ティール (wezterm: 予備 2)
        Color(hex: 0xF87171), // 赤   (wezterm: 予備 3)
        Color(hex: 0xA3E635), // ライム (wezterm: 予備 4)
        Color(hex: 0x818CF8), // 藍   (wezterm: 予備 5)
        Color(hex: 0x9CA3AF), // 灰   (wezterm: local)
    ]

    static func color(forTabIndex index: UInt32) -> Color {
        colors[Int(index) % colors.count]
    }
}

private extension Color {
    /// 0xRRGGBB から sRGB の Color を作る（wezterm 側の "#rrggbb" と同じ値を書けるように）。
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
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
