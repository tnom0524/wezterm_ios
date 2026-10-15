import SwiftUI
import UIKit

// MARK: - BottomAnchoredTextView

/// 初回表示時に最下部へスクロールする UITextView サブクラス。
/// updateUIView が呼ばれた時点ではまだレイアウトが確定していないため、
/// layoutSubviews() のタイミングで確実に最下部へジャンプする。
final class BottomAnchoredTextView: UITextView {
    /// true の間は layoutSubviews で最下部スクロールを試みる
    var pendingInitialBottomScroll = true

    override func layoutSubviews() {
        super.layoutSubviews()
        guard pendingInitialBottomScroll,
              bounds.height > 0,
              contentSize.height > 0 else { return }

        let maxY = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
        contentOffset = CGPoint(x: 0, y: maxY)

        // コンテンツがビューポートを超えたら初期スクロール完了とみなす
        if contentSize.height > bounds.height {
            pendingInitialBottomScroll = false
        }
    }
}

// MARK: - SelectableTextView

/// 選択可能なテキストビュー（UITextView ラッパー）。ユーザーがテキストを選択して
/// ネイティブのコピー操作を行えるようにする。
/// 初回表示は最下部（最新コンテンツ）にスクロールし、テキスト更新時は
/// 下端からの距離を維持して視覚的位置を保つ。
struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> BottomAnchoredTextView {
        let tv = BottomAnchoredTextView()
        // 選択は可能だが編集はできない
        tv.isEditable = false
        tv.isSelectable = true
        // 等幅フォント 14pt（TerminalView と同サイズ）
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textColor = .white
        tv.backgroundColor = .black
        // オートコレクション / スマート機能をすべて無効化
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ uiView: BottomAnchoredTextView, context: Context) {
        if uiView.pendingInitialBottomScroll {
            // 初回スクロール待ち: テキストをセットするだけ（スクロールは layoutSubviews に委ねる）
            uiView.text = text
        } else if uiView.text != text {
            // テキストが更新された（「さらに読み込む」で上方向に追記）:
            // 下端からの距離を維持して視覚的位置を保つ
            let oldDistanceFromBottom = uiView.contentSize.height - uiView.contentOffset.y
            uiView.text = text
            uiView.layoutIfNeeded()
            let newOffsetY = uiView.contentSize.height - oldDistanceFromBottom
            uiView.contentOffset = CGPoint(x: 0, y: max(0, newOffsetY))
        }
    }
}

// MARK: - CopyPayload

/// Sheet 提示に使う Identifiable ラッパー。UUID でユニーク性を保証する。
struct CopyPayload: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - CopySheetView

/// 画面内容を凍結し、ユーザーが選択・コピーできるシート。
/// loadOlder が非 nil のとき「さらに読み込む」ボタンを表示し、古い履歴を追加取得できる。
struct CopySheetView: View {
    let text: String
    /// 古い履歴をさらに取得するクロージャ。新テキストを返す。取得済みなら nil。
    let loadOlder: (() async -> String?)?

    @Environment(\.dismiss) private var dismiss

    /// 表示テキスト（「さらに読み込む」で更新される）
    @State private var displayText: String
    /// 「全てコピー」ボタンの押下後フィードバック状態
    @State private var didCopyAll = false
    /// 「さらに読み込む」実行中フラグ
    @State private var isLoadingOlder = false
    /// まだ古い履歴が存在するかどうか（false になったらボタンを非表示）
    @State private var hasMoreHistory = true

    init(text: String, loadOlder: (() async -> String?)? = nil) {
        self.text = text
        self.loadOlder = loadOlder
        self._displayText = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 「さらに読み込む」ボタン（非 mouseGrabbed ペインかつ履歴がある間のみ表示）
                if let loadOlder, hasMoreHistory {
                    Button {
                        guard !isLoadingOlder else { return }
                        isLoadingOlder = true
                        Task {
                            if let newText = await loadOlder() {
                                displayText = newText
                            } else {
                                hasMoreHistory = false
                            }
                            isLoadingOlder = false
                        }
                    } label: {
                        if isLoadingOlder {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(8)
                        } else {
                            Text("さらに読み込む")
                                .frame(maxWidth: .infinity)
                                .padding(8)
                        }
                    }
                    .background(Color(.systemGray5))
                    Divider()
                }

                SelectableTextView(text: displayText)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("コピー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左: 閉じるボタン
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                // 右: 全てコピーボタン（押下後は一時的にチェックマーク表示）
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = displayText
                        didCopyAll = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            didCopyAll = false
                        }
                    } label: {
                        if didCopyAll {
                            Label("コピー済み", systemImage: "checkmark")
                        } else {
                            Text("全てコピー")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
