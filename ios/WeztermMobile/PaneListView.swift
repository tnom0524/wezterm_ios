import SwiftUI

struct PaneListView: View {
    @ObservedObject var store: ConnectionStore
    let addr: String

    @State private var selectedPane: PaneInfo? = nil

    /// 起動引数 --autoattach で active pane に自動 attach する
    private var autoAttach: Bool {
        ProcessInfo.processInfo.arguments.contains("--autoattach")
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
                if autoAttach, let active = store.panes.first(where: { $0.active }) ?? store.panes.first {
                    await store.attach(pane: active)
                    selectedPane = active
                }
            }
        }
        .navigationDestination(item: $selectedPane) { pane in
            TerminalView(store: store, pane: pane)
        }
    }

    private var paneList: some View {
        List(store.panes, id: \.paneId) { pane in
            Button(action: {
                Task {
                    await store.attach(pane: pane)
                    selectedPane = pane
                }
            }) {
                HStack {
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
