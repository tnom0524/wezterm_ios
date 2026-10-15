import Foundation
import SwiftUI

// MARK: - Data Model

/// ユーザー定義のテキストスニペット。ラベルと送信テキストをペアで保持する。
struct Snippet: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var text: String
}

// MARK: - SnippetStore

/// スニペット一覧を UserDefaults に永続化するストア。
/// ConnectionListStore のパターンを踏襲する。
@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = []

    private let defaultsKey = "snippets.v1"

    /// 初回のみシードするためのキー
    private let seedKey = "seededSnippets.v1"

    /// シードスニペット。
    /// 解説: Claude Codeの表示モード切替。iPhoneではクラシック表示が快適
    private static let seededSnippets: [(label: String, text: String)] = [
        ("CC: モバイル表示", "/tui default"),
        ("CC: フル表示",   "/tui fullscreen"),
    ]

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        }

        // 一度だけシードを挿入する（ユーザーが削除・編集したものを勝手に復活させない）
        if !UserDefaults.standard.bool(forKey: seedKey) {
            for seed in Self.seededSnippets
                where !snippets.contains(where: { $0.label == seed.label }) {
                snippets.append(Snippet(id: UUID(), label: seed.label, text: seed.text))
            }
            UserDefaults.standard.set(true, forKey: seedKey)
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        save()
    }
}

// MARK: - SnippetEditorView

/// スニペット一覧の管理画面。
/// 追加・削除・編集ができる。ダークスキーム固定。
struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SnippetStore

    /// 編集中のスニペット（nil = 非表示）
    @State private var editingSnippet: Snippet? = nil
    /// 新規追加フラグ
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.snippets) { snippet in
                    // タップで編集シートを開く
                    Button {
                        editingSnippet = snippet
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snippet.label)
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(snippet.text)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontDesign(.monospaced)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.delete(at: offsets)
                }
            }
            .navigationTitle("スニペット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 追加ボタン
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                // 完了ボタン
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完了") { dismiss() }
                }
            }
            // 既存スニペット編集シート
            .sheet(item: $editingSnippet) { snippet in
                SnippetFormSheet(mode: .edit(snippet)) { updated in
                    store.update(updated)
                }
            }
            // 新規スニペット追加シート
            .sheet(isPresented: $showAddSheet) {
                SnippetFormSheet(mode: .add) { newSnippet in
                    store.add(newSnippet)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - SnippetFormSheet

/// スニペットの追加 / 編集フォーム。
struct SnippetFormSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case add
        case edit(Snippet)
    }

    let mode: Mode
    let onSave: (Snippet) -> Void

    @State private var label: String
    @State private var text: String
    @State private var showValidationError = false

    init(mode: Mode, onSave: @escaping (Snippet) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add:
            _label = State(initialValue: "")
            _text  = State(initialValue: "")
        case .edit(let snippet):
            _label = State(initialValue: snippet.label)
            _text  = State(initialValue: snippet.text)
        }
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("スニペット情報") {
                    // ラベル（表示名）
                    TextField("ラベル", text: $label)
                        .autocorrectionDisabled()

                    // 送信テキスト（等幅・自動補正なし）
                    TextField("テキスト", text: $text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }

                if showValidationError {
                    Section {
                        Text("ラベルとテキストは必須です")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditMode ? "スニペットを編集" : "スニペットを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
                        let trimmedText  = text.trimmingCharacters(in: .whitespaces)
                        guard !trimmedLabel.isEmpty, !trimmedText.isEmpty else {
                            showValidationError = true
                            return
                        }
                        let snippet: Snippet
                        switch mode {
                        case .add:
                            snippet = Snippet(id: UUID(), label: trimmedLabel, text: trimmedText)
                        case .edit(let existing):
                            snippet = Snippet(id: existing.id, label: trimmedLabel, text: trimmedText)
                        }
                        onSave(snippet)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
