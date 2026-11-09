// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// Keyboard input for the guest.
///
/// A hidden text field lets iOS deliver committed input-method text (including
/// marked-text composition) while hardware keys still use their HID codes. The
/// on-screen keyboard has no key-up events, so mapped characters are synthesized
/// as press/release pairs. Text outside the US key map is sent through Android's
/// `input text` command, which may still be limited by the guest's keyboard map.
final class KeyCapturingView: UITextField, UITextFieldDelegate {

    override var canBecomeFirstResponder: Bool { true }

    private var wantsFirstResponder = false
    private var deliveredText = ""
    private var heldHardwareKeys = Set<String>()

    private static let softwareInputQueue = DispatchQueue(label: "husk.keyboard.software-input",
                                                           qos: .userInitiated)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        borderStyle = .none
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        font = .systemFont(ofSize: 1)
        keyboardType = .default
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        delegate = self
        addTarget(self, action: #selector(textDidChange), for: .editingChanged)
    }

    func setActive(_ active: Bool) {
        wantsFirstResponder = active
        if active {
            focusIfReady()
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFirstResponder { focusIfReady() }
    }

    private func focusIfReady() {
        guard wantsFirstResponder, window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFirstResponder, self.window != nil else { return }
            if !self.becomeFirstResponder() {
                HuskLog.log("kbd", "could not focus the guest keyboard input view")
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseHardwareKeys()
        return super.resignFirstResponder()
    }

    override func deleteBackward() {
        let hadText = !(text ?? "").isEmpty
        super.deleteBackward()
        if !hadText {
            Self.softwareInputQueue.async { Self.tap("backspace") }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard markedTextRange == nil else { return false }
        Self.softwareInputQueue.async { Self.tap("ret") }
        return false
    }

    @objc private func textDidChange() {
        // Do not leak partial IME composition into the guest. Once the input
        // method commits, diff against the last delivered string and forward it.
        guard markedTextRange == nil else { return }
        let currentText = text ?? ""
        guard currentText != deliveredText else { return }

        let oldCharacters = Array(deliveredText)
        let newCharacters = Array(currentText)
        var prefix = 0
        while prefix < oldCharacters.count && prefix < newCharacters.count
                && oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        var oldEnd = oldCharacters.count
        var newEnd = newCharacters.count
        while oldEnd > prefix && newEnd > prefix
                && oldCharacters[oldEnd - 1] == newCharacters[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let backspaces = oldEnd - prefix
        let inserted = newEnd > prefix ? String(newCharacters[prefix..<newEnd]) : ""
        deliveredText = currentText
        guard backspaces > 0 || !inserted.isEmpty else { return }

        Self.softwareInputQueue.async {
            for _ in 0..<backspaces { Self.tap("backspace") }
            Self.sendInsertedText(inserted)
        }
    }

    private func releaseHardwareKeys() {
        for qcode in heldHardwareKeys.sorted() {
            _ = husk_display_send_key(qcode, false)
        }
        heldHardwareKeys.removeAll()
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let qcode = Self.hidMap[key.keyCode] {
                heldHardwareKeys.insert(qcode)
                _ = husk_display_send_key(qcode, true)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let qcode = Self.hidMap[key.keyCode] {
                heldHardwareKeys.remove(qcode)
                _ = husk_display_send_key(qcode, false)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let qcode = Self.hidMap[key.keyCode] {
                heldHardwareKeys.remove(qcode)
                _ = husk_display_send_key(qcode, false)
                handled = true
            }
        }
        if !handled { super.pressesCancelled(presses, with: event) }
    }

    /// Mapped characters use QEMU key events. The fallback asks Android to map
    /// the remaining text; Android does not promise arbitrary Unicode support
    /// unless its active keyboard layout can represent those characters.
    private static func sendInsertedText(_ text: String) {
        var unmapped = ""

        func flushUnmapped() {
            guard !unmapped.isEmpty else { return }
            let value = unmapped
            unmapped = ""
            do {
                _ = try GuestBridge.shared.shell("input text \(shellQuoted(value))", timeout: 8)
                HuskLog.log("kbd", "sent \(value.unicodeScalars.count) non-keymapped scalar(s) to Android input text")
            } catch {
                HuskLog.log("kbd", "Android text fallback failed: \(error.localizedDescription)")
            }
        }

        for character in text {
            if character == "\n" || character == "\r" {
                flushUnmapped()
                tap("ret")
            } else if character == " " {
                flushUnmapped()
                tap("spc")
            } else if let (qcode, needsShift) = characterMap[character] {
                flushUnmapped()
                if needsShift { _ = husk_display_send_key("shift", true) }
                tap(qcode)
                if needsShift { _ = husk_display_send_key("shift", false) }
            } else {
                unmapped.append(character)
            }
        }
        flushUnmapped()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tap(_ qcode: String) {
        _ = husk_display_send_key(qcode, true)
        _ = husk_display_send_key(qcode, false)
    }

    // MARK: - Maps

    /// HID usage -> QEMU QKeyCode name.
    static let hidMap: [UIKeyboardHIDUsage: String] = {
        var m: [UIKeyboardHIDUsage: String] = [:]

        // Letters are contiguous from keyboardA, and so are their names.
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for (i, ch) in letters.enumerated() {
            if let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardA.rawValue + i) {
                m[usage] = String(ch)
            }
        }
        // Digits run 1..9 then 0, in that order, in both schemes.
        for (i, name) in ["1","2","3","4","5","6","7","8","9","0"].enumerated() {
            if let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboard1.rawValue + i) {
                m[usage] = name
            }
        }
        for i in 0..<12 {
            if let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardF1.rawValue + i) {
                m[usage] = "f\(i + 1)"
            }
        }

        let rest: [UIKeyboardHIDUsage: String] = [
            .keyboardReturnOrEnter: "ret",
            .keyboardEscape: "esc",
            .keyboardDeleteOrBackspace: "backspace",
            .keyboardTab: "tab",
            .keyboardSpacebar: "spc",
            .keyboardHyphen: "minus",
            .keyboardEqualSign: "equal",
            .keyboardOpenBracket: "bracket_left",
            .keyboardCloseBracket: "bracket_right",
            .keyboardBackslash: "backslash",
            .keyboardSemicolon: "semicolon",
            .keyboardQuote: "apostrophe",
            .keyboardGraveAccentAndTilde: "grave_accent",
            .keyboardComma: "comma",
            .keyboardPeriod: "dot",
            .keyboardSlash: "slash",
            .keyboardCapsLock: "caps_lock",
            .keyboardLeftArrow: "left",
            .keyboardRightArrow: "right",
            .keyboardUpArrow: "up",
            .keyboardDownArrow: "down",
            .keyboardHome: "home",
            .keyboardEnd: "end",
            .keyboardPageUp: "pgup",
            .keyboardPageDown: "pgdn",
            .keyboardDeleteForward: "delete",
            .keyboardInsert: "insert",
            .keyboardPrintScreen: "print",
            .keyboardLeftShift: "shift",
            .keyboardRightShift: "shift_r",
            .keyboardLeftControl: "ctrl",
            .keyboardRightControl: "ctrl_r",
            .keyboardLeftAlt: "alt",
            .keyboardRightAlt: "alt_r",
            .keyboardLeftGUI: "meta_l",
            .keyboardRightGUI: "meta_r",
        ]
        m.merge(rest) { a, _ in a }
        return m
    }()

    /// Character -> (QKeyCode name, needs shift). US layout, which is what the
    /// guest is configured for.
    static let characterMap: [Character: (String, Bool)] = {
        var m: [Character: (String, Bool)] = [:]
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            m[ch] = (String(ch), false)
            m[Character(ch.uppercased())] = (String(ch), true)
        }
        let digits: [(Character, String, Character)] = [
            ("1","1","!"), ("2","2","@"), ("3","3","#"), ("4","4","$"), ("5","5","%"),
            ("6","6","^"), ("7","7","&"), ("8","8","*"), ("9","9","("), ("0","0",")"),
        ]
        for (d, name, shifted) in digits {
            m[d] = (name, false)
            m[shifted] = (name, true)
        }
        let punct: [(Character, String, Character?)] = [
            ("-", "minus", "_"), ("=", "equal", "+"),
            ("[", "bracket_left", "{"), ("]", "bracket_right", "}"),
            ("\\", "backslash", "|"), (";", "semicolon", ":"),
            ("'", "apostrophe", "\""), ("`", "grave_accent", "~"),
            (",", "comma", "<"), (".", "dot", ">"), ("/", "slash", "?"),
        ]
        for (base, name, shifted) in punct {
            m[base] = (name, false)
            if let sh = shifted { m[sh] = (name, true) }
        }
        return m
    }()
}

/// SwiftUI wrapper that owns first-responder state.
struct KeyCapture: UIViewRepresentable {
    @Binding var active: Bool

    func makeUIView(context: Context) -> KeyCapturingView {
        let view = KeyCapturingView(frame: .zero)
        view.isUserInteractionEnabled = true
        view.setActive(active)
        return view
    }

    func updateUIView(_ view: KeyCapturingView, context: Context) {
        // The view retries focus once it is attached to a window; doing it here
        // also covers an already-mounted representable becoming active later.
        view.setActive(active)
    }

    static func dismantleUIView(_ view: KeyCapturingView, coordinator: ()) {
        view.setActive(false)
    }
}

/// The keys a touch-only user cannot otherwise reach, and that Android and a
/// Debian console both need constantly.
struct SpecialKeysBar: View {
    @State private var ctrlLatched = false

    private let keys: [(String, String)] = [
        ("esc", "esc"), ("tab", "tab"), ("⌫", "backspace"), ("↵", "ret"),
        ("←", "left"), ("↓", "down"), ("↑", "up"), ("→", "right"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            // Ctrl latches rather than repeats: there is no chord to hold on a
            // touchscreen, so tap Ctrl, then tap the letter.
            Button {
                ctrlLatched.toggle()
                _ = husk_display_send_key("ctrl", ctrlLatched)
                HuskLog.log("kbd", "ctrl \(ctrlLatched ? "held" : "released")")
            } label: {
                Text("ctrl")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(ctrlLatched ? AnyShapeStyle(Theme.accent)
                                            : AnyShapeStyle(Theme.surfaceHigh),
                                in: RoundedRectangle(cornerRadius: 7))
            }

            ForEach(keys, id: \.1) { label, qcode in
                Button {
                    _ = husk_display_send_key(qcode, true)
                    _ = husk_display_send_key(qcode, false)
                    if ctrlLatched {
                        ctrlLatched = false
                        _ = husk_display_send_key("ctrl", false)
                    }
                } label: {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .frame(minWidth: 26)
                        .padding(.horizontal, 7).padding(.vertical, 6)
                        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .foregroundStyle(.primary)
        .onDisappear {
            if ctrlLatched {
                _ = husk_display_send_key("ctrl", false)
                ctrlLatched = false
            }
        }
    }
}
