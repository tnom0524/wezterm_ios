import SwiftUI
import UIKit

// MARK: - UITextPosition / UITextRange helpers

/// ドキュメント内の位置（オフセット単位: String.UTF16View.Index）
final class TermTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

/// ドキュメント内の範囲
final class TermTextRange: UITextRange {
    private let _start: TermTextPosition
    private let _end: TermTextPosition
    override var start: UITextPosition { _start }
    override var end: UITextPosition { _end }
    override var isEmpty: Bool { _start.offset >= _end.offset }

    init(start: Int, end: Int) {
        _start = TermTextPosition(start)
        _end   = TermTextPosition(end)
    }
    init(start: TermTextPosition, end: TermTextPosition) {
        _start = start
        _end   = end
    }
}

// MARK: - TerminalKeyView (UITextInput)

/// ターミナルアプリの定石: UIView + UITextInput でソフトキーボード入力を直接受け取る。
/// "fake document" 方式: ドキュメント = 変換中テキスト(markedText)のみ。
/// 確定文字だけを onText に流し、未確定中は IME が setMarkedText で管理する。
final class TerminalKeyView: UIView, UITextInput {

    // MARK: Terminal output callback

    var onText: ((Data) -> Void)?
    var ctrlMode = false
    var onCtrlConsumed: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    /// 変換中テキストが変化したとき呼ばれる（nil = 変換終了）
    var onMarkedTextChanged: ((String?) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Internal document state

    /// 変換中文字列（nil = IME非活性）
    private var markedText: String? = nil

    /// ドキュメント文字列（常に markedText ?? ""）
    private var documentText: String { markedText ?? "" }

    /// ドキュメント内の "選択範囲"（変換中カーソル位置）
    private var selectedRangeInDoc: NSRange = NSRange(location: 0, length: 0)

    // MARK: - UITextInput required properties

    var inputDelegate: (any UITextInputDelegate)?

    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    // MARK: - UITextInputTraits

    var keyboardType: UIKeyboardType = .default          // .asciiCapable を廃止 — 日本語キーボードを出すため
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // MARK: - UIKeyInput (still required as part of UITextInput)

    var hasText: Bool { !(markedText ?? "").isEmpty }

    /// 確定入力。Ctrlトグル / \n→\r / UTF-8送信 の既存ロジックを維持。
    func insertText(_ text: String) {
        // 変換確定: markedText をクリア
        if markedText != nil {
            notifyTextWillChange()
            markedText = nil
            selectedRangeInDoc = NSRange(location: 0, length: 0)
            notifyTextDidChange()
            onMarkedTextChanged?(nil)
        }

        var bytes = Array(text.utf8)
        if ctrlMode && bytes.count == 1 {
            let b = bytes[0]
            if b >= 0x40 && b <= 0x7E {
                bytes[0] = b & 0x1F
            }
            ctrlMode = false
            onCtrlConsumed?()
        }
        // 改行は \r に変換
        if bytes == [0x0A] { bytes = [0x0D] }
        onText?(Data(bytes))
    }

    func deleteBackward() {
        if markedText != nil {
            // 変換中の削除は IME が setMarkedText で面倒を見る — ここでは何もしない
            return
        }
        onText?(Data([0x7f]))
    }

    // MARK: - setMarkedText / unmarkText

    func setMarkedText(_ markedTextParam: String?, selectedRange: NSRange) {
        notifySelectionWillChange()
        notifyTextWillChange()

        let newText = markedTextParam ?? ""
        if newText.isEmpty {
            // IME がクリアした = 未確定テキスト削除
            markedText = nil
            selectedRangeInDoc = NSRange(location: 0, length: 0)
        } else {
            markedText = newText
            // selectedRange は markedText 内のオフセット（UIKit仕様）
            let len = newText.utf16.count
            let loc = min(selectedRange.location, len)
            let length = min(selectedRange.length, max(0, len - loc))
            selectedRangeInDoc = NSRange(location: loc, length: length)
        }

        notifyTextDidChange()
        notifySelectionDidChange()
        onMarkedTextChanged?(markedText)
    }

    func unmarkText() {
        guard let text = markedText, !text.isEmpty else {
            markedText = nil
            selectedRangeInDoc = NSRange(location: 0, length: 0)
            onMarkedTextChanged?(nil)
            return
        }
        // 変換確定扱い: markedText の内容をそのまま送信
        notifyTextWillChange()
        markedText = nil
        selectedRangeInDoc = NSRange(location: 0, length: 0)
        notifyTextDidChange()
        onMarkedTextChanged?(nil)

        var bytes = Array(text.utf8)
        if bytes == [0x0A] { bytes = [0x0D] }
        onText?(Data(bytes))
    }

    // MARK: - Text range / position

    var beginningOfDocument: UITextPosition { TermTextPosition(0) }
    var endOfDocument: UITextPosition { TermTextPosition(documentText.utf16.count) }

    var markedTextRange: UITextRange? {
        guard let m = markedText, !m.isEmpty else { return nil }
        return TermTextRange(start: 0, end: m.utf16.count)
    }

    var selectedTextRange: UITextRange? {
        get {
            let loc = selectedRangeInDoc.location
            let end = loc + selectedRangeInDoc.length
            return TermTextRange(start: loc, end: end)
        }
        set {
            guard let r = newValue as? TermTextRange else { return }
            let s = r.start as! TermTextPosition
            let e = r.end   as! TermTextPosition
            selectedRangeInDoc = NSRange(location: s.offset, length: e.offset - s.offset)
        }
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { return nil }
        set { }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let f = fromPosition as? TermTextPosition,
              let t = toPosition   as? TermTextPosition else { return nil }
        let lo = min(f.offset, t.offset)
        let hi = max(f.offset, t.offset)
        return TermTextRange(start: lo, end: hi)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? TermTextPosition else { return nil }
        let newOffset = p.offset + offset
        let len = documentText.utf16.count
        guard newOffset >= 0 && newOffset <= len else { return nil }
        return TermTextPosition(newOffset)
    }

    func position(from position: UITextPosition,
                  in direction: UITextLayoutDirection,
                  offset: Int) -> UITextPosition? {
        guard let p = position as? TermTextPosition else { return nil }
        let delta = (direction == .left || direction == .up) ? -offset : offset
        let newOffset = p.offset + delta
        let len = documentText.utf16.count
        guard newOffset >= 0 && newOffset <= len else { return nil }
        return TermTextPosition(newOffset)
    }

    func position(within range: UITextRange,
                  farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? TermTextRange else { return nil }
        // left/up = 範囲の先頭、right/down = 範囲の末尾
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    func characterRange(byExtending position: UITextPosition,
                        in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? TermTextPosition else { return nil }
        let len = documentText.utf16.count
        if direction == .left || direction == .up {
            return TermTextRange(start: max(0, p.offset - 1), end: p.offset)
        } else {
            return TermTextRange(start: p.offset, end: min(len, p.offset + 1))
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? TermTextPosition,
              let b = other    as? TermTextPosition else { return .orderedSame }
        if a.offset < b.offset { return .orderedAscending }
        if a.offset > b.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let f = from         as? TermTextPosition,
              let t = toPosition   as? TermTextPosition else { return 0 }
        return t.offset - f.offset
    }

    // MARK: - Text access

    func text(in range: UITextRange) -> String? {
        guard let r = range as? TermTextRange else { return nil }
        let s = r.start as! TermTextPosition
        let e = r.end   as! TermTextPosition
        let doc = documentText
        let utf16 = doc.utf16
        guard s.offset >= 0, e.offset <= utf16.count, s.offset <= e.offset else { return nil }
        let startIdx = utf16.index(utf16.startIndex, offsetBy: s.offset)
        let endIdx   = utf16.index(utf16.startIndex, offsetBy: e.offset)
        return String(utf16[startIdx..<endIdx])
    }

    func replace(_ range: UITextRange, withText text: String) {
        // fake document: IME は setMarkedText で更新するので通常ここには来ない。
        // 念のため: ドキュメントの対応範囲を text で置き換えて markedText を更新
        guard let r = range as? TermTextRange else { return }
        let s = (r.start as! TermTextPosition).offset
        let e = (r.end   as! TermTextPosition).offset
        var doc = documentText
        let utf16 = doc.utf16
        guard s >= 0, e <= utf16.count, s <= e else { return }
        let si = utf16.index(utf16.startIndex, offsetBy: s)
        let ei = utf16.index(utf16.startIndex, offsetBy: e)
        doc.replaceSubrange(si..<ei, with: text)
        markedText = doc.isEmpty ? nil : doc
        selectedRangeInDoc = NSRange(location: s + text.utf16.count, length: 0)
        onMarkedTextChanged?(markedText)
    }

    // MARK: - Geometry (dummy — candidate window positioning only)

    func firstRect(for range: UITextRange) -> CGRect { bounds }

    func caretRect(for position: UITextPosition) -> CGRect {
        CGRect(x: 0, y: 0, width: 2, height: bounds.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        TermTextPosition(documentText.utf16.count)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        (range as? TermTextRange).map { ($0.end as! TermTextPosition) }
    }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    func baseWritingDirection(for position: UITextPosition,
                              in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) { }

    // MARK: - Private: inputDelegate notifications

    private func notifyTextWillChange() {
        inputDelegate?.textWillChange(self)
    }
    private func notifyTextDidChange() {
        inputDelegate?.textDidChange(self)
    }
    private func notifySelectionWillChange() {
        inputDelegate?.selectionWillChange(self)
    }
    private func notifySelectionDidChange() {
        inputDelegate?.selectionDidChange(self)
    }

    // MARK: - First responder tracking

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChanged?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChanged?(false) }
        return ok
    }
}

// MARK: - SwiftUI Wrapper

struct TerminalKeyInput: UIViewRepresentable {
    let store: ConnectionStore
    @Binding var ctrlMode: Bool
    @Binding var isFocused: Bool
    @Binding var composingText: String?

    func makeUIView(context: Context) -> TerminalKeyView {
        let v = TerminalKeyView()
        v.backgroundColor = .clear
        v.onText = { [weak store] data in
            store?.sendInput(data: data)
        }
        return v
    }

    func updateUIView(_ uiView: TerminalKeyView, context: Context) {
        uiView.ctrlMode = ctrlMode
        uiView.onCtrlConsumed = {
            DispatchQueue.main.async {
                if ctrlMode { ctrlMode = false }
            }
        }
        uiView.onFocusChanged = { focused in
            DispatchQueue.main.async {
                if isFocused != focused { isFocused = focused }
            }
        }
        uiView.onMarkedTextChanged = { text in
            DispatchQueue.main.async {
                composingText = text
            }
        }
        // フォーカス状態を first responder に反映（main.async で更新サイクル外に）
        if isFocused && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                guard uiView.window != nil else { return }
                _ = uiView.becomeFirstResponder()
            }
        } else if !isFocused && uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.resignFirstResponder()
            }
        }
    }
}

// MARK: - KeyInputView (accessory bar + composing strip + key dispatcher)

struct KeyInputView: View {
    @ObservedObject var store: ConnectionStore
    @State private var ctrlMode = false
    @Binding var isKeyboardShown: Bool
    @Binding var composingText: String?

    var body: some View {
        ZStack(alignment: .top) {
            // アクセサリバー
            HStack(spacing: 0) {
                accessoryButton(label: "Esc")   { sendBytes([0x1B]) }
                accessoryButton(label: "Tab")   { sendBytes([0x09]) }
                accessoryButton(label: ctrlMode ? "CTRL" : "Ctrl",
                                active: ctrlMode) {
                    ctrlMode.toggle()
                }
                accessoryButton(label: "↑") { sendBytes([0x1B, 0x5B, 0x41]) }
                accessoryButton(label: "↓") { sendBytes([0x1B, 0x5B, 0x42]) }
                accessoryButton(label: "←") { sendBytes([0x1B, 0x5B, 0x44]) }
                accessoryButton(label: "→") { sendBytes([0x1B, 0x5B, 0x43]) }
                accessoryButton(label: "^C") { sendBytes([0x03]) }

                Spacer()

                Button(action: toggleKeyboard) {
                    Image(systemName: isKeyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                        .foregroundColor(isKeyboardShown ? .green : .white)
                        .padding(.horizontal, 12)
                }
            }
            .background(Color(white: 0.15))
            .overlay(alignment: .top) {
                // UITextInput ビュー — isFocused が true になるとキーボードが上がる
                TerminalKeyInput(store: store,
                                 ctrlMode: $ctrlMode,
                                 isFocused: $isKeyboardShown,
                                 composingText: $composingText)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }

            // 変換中テキストストリップ（アクセサリバーの上に重ねる）
            if let composing = composingText, !composing.isEmpty {
                composingStrip(text: composing)
            }
        }
    }

    @ViewBuilder
    private func composingStrip(text: String) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(.white)
                .underline()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.25))
        .offset(y: -composingStripHeight)
    }

    private var composingStripHeight: CGFloat { 24 }

    private func accessoryButton(label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(active ? .black : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(active ? Color.yellow : Color(white: 0.3))
                .cornerRadius(5)
        }
        .padding(.horizontal, 2)
    }

    private func sendBytes(_ bytes: [UInt8]) {
        store.sendInput(data: Data(bytes))
    }

    private func toggleKeyboard() {
        isKeyboardShown.toggle()
    }
}
