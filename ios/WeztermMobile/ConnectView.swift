import SwiftUI

// MARK: - Add / Edit Sheet

struct ConnectionFormSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case add
        case edit(SavedConnection)
    }

    let mode: Mode
    let onSave: (SavedConnection) -> Void

    @State private var name: String
    @State private var addr: String
    @State private var showValidationError = false

    init(mode: Mode, onSave: @escaping (SavedConnection) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _addr = State(initialValue: "")
        case .edit(let conn):
            _name = State(initialValue: conn.name)
            _addr = State(initialValue: conn.addr)
        }
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("接続先情報") {
                    TextField("名前", text: $name)
                        .autocorrectionDisabled()
                    TextField("アドレス (host:port)", text: $addr)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if showValidationError {
                    Section {
                        Text("名前とアドレスは必須です")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditMode ? "接続先を編集" : "接続先を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
                              !addr.trimmingCharacters(in: .whitespaces).isEmpty else {
                            showValidationError = true
                            return
                        }
                        let conn: SavedConnection
                        switch mode {
                        case .add:
                            conn = SavedConnection(id: UUID(), name: name.trimmingCharacters(in: .whitespaces), addr: addr.trimmingCharacters(in: .whitespaces))
                        case .edit(let existing):
                            conn = SavedConnection(id: existing.id, name: name.trimmingCharacters(in: .whitespaces), addr: addr.trimmingCharacters(in: .whitespaces))
                        }
                        onSave(conn)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - ConnectView

struct ConnectView: View {
    @StateObject private var listStore = ConnectionListStore()
    @StateObject private var store = ConnectionStore()

    @State private var connectingId: UUID? = nil
    @State private var showAddSheet = false
    @State private var editingConnection: SavedConnection? = nil

    /// 起動引数 --autoconnect: リスト先頭の接続先へ接続
    private var autoConnect: Bool {
        ProcessInfo.processInfo.arguments.contains("--autoconnect")
    }

    var body: some View {
        NavigationStack {
            List {
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
            .navigationTitle("WezTerm Mobile")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
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
            .navigationDestination(isPresented: $store.isConnected) {
                PaneListView(store: store, addr: listStore.connections.first(where: { $0.id == connectingId })?.addr ?? "")
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
            .onAppear {
                if autoConnect, let first = listStore.connections.first {
                    connect(first)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ conn: SavedConnection) -> some View {
        Button {
            connect(conn)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conn.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(conn.addr)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if connectingId == conn.id && store.isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isConnecting)
    }

    private func connect(_ conn: SavedConnection) {
        connectingId = conn.id
        Task { await store.makeConnection(addr: conn.addr) }
    }
}
