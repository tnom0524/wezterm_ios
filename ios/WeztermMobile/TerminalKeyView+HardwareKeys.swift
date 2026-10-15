import UIKit

// MARK: - TerminalKeyView ハードウェアキーボード対応 extension
//
// 実装方針（スパイク結果 2026-07-13 に基づく）:
//   - pressesBegan が全キーを受信する（矢印・Esc 含め）ことを実測確認済み
//   - 特殊キーの判定は key.keyCode (UIKeyboardHIDUsage) で行う
//     （charactersIgnoringModifiers は矢印で 'UIKeyInputUpArrow' 等の複数文字列になるため使用不可）
//   - Cmd+V / Cmd+C は keyCommands で提供（pressesBegan では Cmd 系を処理しない）
//   - キーリピートタイマは v1 なし（実キーボード実測後に判断する）

extension TerminalKeyView {

    // MARK: - pressesBegan

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // IME 変換中は一切横取りしない（候補選択・変換・確定はすべて IME のもの）
        guard !isComposing else {
            super.pressesBegan(presses, with: event)
            return
        }

        var unhandled: Set<UIPress> = []

        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }

            // Cmd を含む場合は keyCommands に委ねる（pressesBegan では処理しない）
            if key.modifierFlags.contains(.command) {
                unhandled.insert(press)
                continue
            }

            // --- 特殊キー（keyCode で判定）---
            if let bytes = specialKeyBytes(for: key.keyCode) {
                onText?(Data(bytes))
                // super を呼ばずに消費（二重送信防止）
                continue
            }

            // --- Ctrl 組み合わせ ---
            if key.modifierFlags.contains(.control),
               !key.modifierFlags.contains(.command),
               !key.modifierFlags.contains(.alternate) {

                // Ctrl + Space → 0x00
                if key.keyCode == .keyboardSpacebar {
                    onText?(Data([0x00]))
                    continue
                }

                // Ctrl + 単一 ASCII 文字 (@ A-Z [ \ ] ^ _)
                let ignMod = key.charactersIgnoringModifiers
                if ignMod.count == 1, let ascii = ignMod.lowercased().first?.asciiValue {
                    if ascii >= 0x40 && ascii <= 0x7E {
                        onText?(Data([ascii & 0x1F]))
                        continue
                    }
                }
            }

            // 未処理（通常文字・Return・Tab・Backspace・Option 文字など）
            unhandled.insert(press)
        }

        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    // MARK: - keyCommands (Cmd 専用)

    override var keyCommands: [UIKeyCommand]? {
        let paste = UIKeyCommand(
            title: "ペースト",
            action: #selector(handleCmdV),
            input: "v",
            modifierFlags: .command
        )
        paste.wantsPriorityOverSystemBehavior = true

        let copy = UIKeyCommand(
            title: "画面をコピー",
            action: #selector(handleCmdC),
            input: "c",
            modifierFlags: .command
        )
        copy.wantsPriorityOverSystemBehavior = true

        return [paste, copy]
    }

    @objc private func handleCmdV() {
        onPasteRequested?()
    }

    @objc private func handleCmdC() {
        onCopyRequested?()
    }

    // MARK: - Private helpers

    /// 特殊キーのエスケープシーケンスバイト列を返す。
    /// 横取り対象でないキーは nil を返す。
    private func specialKeyBytes(for keyCode: UIKeyboardHIDUsage) -> [UInt8]? {
        switch keyCode {
        case .keyboardUpArrow:      return [0x1B, 0x5B, 0x41]
        case .keyboardDownArrow:    return [0x1B, 0x5B, 0x42]
        case .keyboardRightArrow:   return [0x1B, 0x5B, 0x43]
        case .keyboardLeftArrow:    return [0x1B, 0x5B, 0x44]
        case .keyboardEscape:       return [0x1B]
        case .keyboardHome:         return [0x1B, 0x5B, 0x48]
        case .keyboardEnd:          return [0x1B, 0x5B, 0x46]
        case .keyboardPageUp:       return [0x1B, 0x5B, 0x35, 0x7E]
        case .keyboardPageDown:     return [0x1B, 0x5B, 0x36, 0x7E]
        case .keyboardDeleteForward: return [0x1B, 0x5B, 0x33, 0x7E]
        default:                    return nil
        }
    }
}
