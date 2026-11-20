import Foundation
import ThumbFreeCore

/// The dictation's text box lost the focus between two pieces of typing.
struct FieldChanged: Error, LocalizedError {
    var errorDescription: String? { "The text box lost the focus." }
}

/// The desktop the inserter types through (thumbfree-windows `DictationHost.GuardedDesktop`). Right before each paste
/// or key press goes out (after the pasteboard holds the text and held modifier keys are let go: `GatedInput`) it runs
/// `sameField`, again while a modifier key is still held, up to 3 times: ⌘` or ⌘L held while a phrase is typed must not
/// send it to the next window or the address bar. A password field found by the inserter's own check counts as the
/// dictation's only if `sameField` passes too, so moving to a password box somewhere else throws `FieldChanged` and
/// keeps the dictation to copy. It also counts what was typed and remembers the last field check, so a refusal for a
/// password field can be told apart.
final class GuardedDesktop: Desktop, @unchecked Sendable {
    static let maxChecks = 3

    private let inner: Desktop
    private let gated: GatedInput?
    private let typedCount = LockedValue(0)

    /// True while the dictation's box has the focus; nil types anywhere ("paste last dictation"). Typing queue only.
    var sameField: (() -> Bool)?

    /// The inserter's last field check since `resetCheck`. Typing queue only.
    private(set) var lastCheck = FieldCheck.unknown

    init(_ inner: Desktop) {
        self.inner = inner
        gated = inner as? GatedInput
    }

    /// How many times text or keys went into an app.
    var typed: Int { typedCount.value }

    func resetCheck() {
        lastCheck = .unknown
    }

    func foregroundWindow() -> WindowInfo? { inner.foregroundWindow() }

    func checkFocusedField() throws -> FieldCheck {
        let check = try inner.checkFocusedField()
        if check == .password {
            try checkSameField()
        }

        lastCheck = check
        return check
    }

    func focusedTextEndsWithNonWhitespace() -> Bool? { inner.focusedTextEndsWithNonWhitespace() }

    func typeText(_ text: String) throws {
        if let gated {
            try gated.typeText(text, beforeKeys: checkSameField)
        } else {
            try checkSameField()
            try inner.typeText(text)
        }

        typedCount.update { $0 += 1 }
    }

    func pressKeys(_ chord: String) throws {
        if let gated {
            try gated.pressKeys(chord, beforeKeys: checkSameField)
        } else {
            try checkSameField()
            try inner.pressKeys(chord)
        }

        typedCount.update { $0 += 1 }
    }

    private func checkSameField() throws {
        guard let sameField else { return }
        for _ in 0..<Self.maxChecks {
            gated?.waitForModifiers()
            if !sameField() {
                throw FieldChanged()
            }

            // A key pressed while the check ran (it can take a second) may have moved the focus since.
            if gated?.modifiersDown != true {
                return
            }
        }
    }
}
