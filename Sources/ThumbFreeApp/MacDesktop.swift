import AppKit
import ThumbFreeCore
import ThumbFreeMac

/// The Mac's side of ThumbFreeCore's `Desktop` (thumbfree-windows `WindowsDesktop`): the app in front from
/// NSWorkspace, the field checks through the Accessibility API (`FocusedField.Reader`), and typing with `PasteTyper`,
/// whose check right before the keys go out is `GatedInput`'s. `GuardedDesktop` adds the dictation's same-box guard.
/// What PasteTyper throws comes through (`PasteTyper.Failure`), so the host keeps the dictation to copy. Typing calls
/// wait (for held keys, the pasteboard, the app's answers): make them off the main thread, one at a time.
public final class MacDesktop: Desktop, GatedInput, @unchecked Sendable {
    /// A new-line key in settings.json that isn't keys ThumbFree knows.
    public struct UnknownKeys: Error, Equatable, LocalizedError {
        public let chord: String

        public var errorDescription: String? {
            "The new-line keys “\(chord)” in settings.json aren't keys ThumbFree knows."
        }
    }

    private let typer: PasteTyper
    private let reader: FocusedField.Reader
    private let insertMethod: () -> String
    private let frontmost: () -> WindowInfo?

    /// - Parameters:
    ///   - insertMethod: The insertMethod setting, read before each piece: "Paste", or "Type" for key events.
    ///   - frontmost: The app in front; `MacDesktop.frontmostApp` when nil.
    public init(
        typer: PasteTyper, reader: FocusedField.Reader, insertMethod: @escaping () -> String,
        frontmost: (() -> WindowInfo?)? = nil
    ) {
        self.typer = typer
        self.reader = reader
        self.insertMethod = insertMethod
        self.frontmost = frontmost ?? MacDesktop.frontmostApp
    }

    /// The app in front as a window: its process identifier is the handle, its executable's name the process name (as
    /// new-line keys know it: macOS never translates it, as it does some apps' names), and its name as macOS shows it
    /// the app name. Its window's title isn't read: that would ask the app through the Accessibility API, which mustn't
    /// hold up the main thread, where dictation starts. Nil for ThumbFree itself.
    public static func frontmostApp() -> WindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = Int(app.processIdentifier)
        let process = app.executableURL?.lastPathComponent ?? app.localizedName ?? ""
        return WindowInfo(handle: pid, processId: pid, processName: process, title: "", appName: app.localizedName)
    }

    public func foregroundWindow() -> WindowInfo? { frontmost() }

    /// A password box (AXSecureTextField) has the focus, or not. Secure input on somewhere else isn't a password box
    /// here: PasteTyper refuses to type then, and the dictation is kept to copy.
    public func checkFocusedField() throws -> FieldCheck {
        guard let field = reader.read() else { return .unknown }
        return field.isSecure ? .password : .safe
    }

    public func focusedTextEndsWithNonWhitespace() -> Bool? {
        guard let field = reader.read(), !field.isSecure, let before = field.textBefore else { return nil }
        guard let last = before.unicodeScalars.last else { return false }
        return !DotNet.isWhiteSpace(last)
    }

    public func typeText(_ text: String) throws {
        try typeText(text, beforeKeys: {})
    }

    /// Pastes (or, with insertMethod "Type", types) `text`, its line breaks as spaces. `beforeKeys` runs last, right
    /// before ⌘V or the keys: after the pasteboard holds the text and held modifier keys are let go. If it throws,
    /// nothing is typed and the pasteboard goes back.
    public func typeText(_ text: String, beforeKeys: () throws -> Void) throws {
        typer.insertMethod = DotNet.equalsOrdinalIgnoreCase(insertMethod(), "Paste") ? .paste : .typeWithKeys
        try typer.paste(text, beforeKeys: beforeKeys)
    }

    public func pressKeys(_ chord: String) throws {
        try pressKeys(chord, beforeKeys: {})
    }

    /// Presses keys as settings write them ("Shift+Enter", "Enter"); `UnknownKeys` for any others.
    public func pressKeys(_ chord: String, beforeKeys: () throws -> Void) throws {
        guard let keys = PasteTyper.Chord(chord) else { throw UnknownKeys(chord: chord) }
        try typer.press(keys, beforeKeys: beforeKeys)
    }

    public func waitForModifiers() {
        typer.waitForModifiersReleased()
    }

    public var modifiersDown: Bool { typer.modifiersDown }
}

/// The focused box through the Accessibility API (`FocusedField.Reader`), for the host (thumbfree-windows
/// `UiaFieldReader`). The reader reads the box taking the keys, whichever app it's in.
public final class MacFieldReader: FieldReader, @unchecked Sendable {
    private let reader: FocusedField.Reader

    public init(_ reader: FocusedField.Reader) {
        self.reader = reader
    }

    public func read(_ window: WindowInfo) -> DictationField? {
        reader.read().map { DictationField($0, window: window) }
    }

    /// A box whose web page hadn't described it: the box there now (`FocusedField.Reader.resolved`). Any other: read
    /// again while the focus is still in it.
    public func readAgain(_ start: DictationField) -> DictationField? {
        guard let focused = start.focused else { return nil }
        if !focused.isResolved {
            return reader.resolved(focused).map { DictationField($0, window: start.window) }
        }

        guard reader.isSameField(focused) == true, let again = reader.read() else { return nil }
        return DictationField(again, window: start.window)
    }

    /// The Accessibility API's answer (`FocusedField.Reader.isSameField`), which knows the app taking the keys (a box
    /// in Spotlight or a notification's reply while the app behind stays in front). With no app in front (ThumbFree
    /// itself), it's another box.
    public func isSameField(_ start: DictationField, _ now: WindowInfo?) -> Bool? {
        guard now != nil else { return false }
        guard let focused = start.focused else { return now?.handle == start.window.handle }
        return reader.isSameField(focused)
    }

    public func app(of window: WindowInfo) -> TargetApp {
        let running = NSRunningApplication(processIdentifier: pid_t(window.processId))
        return TargetApp(
            name: running?.localizedName ?? window.processName, bundleIdentifier: running?.bundleIdentifier)
    }
}

/// The microphone (ThumbFreeMac's `AudioCapture`) as the host's `AudioSource`. Made, started and stopped on the main
/// thread, as AudioCapture is; its samples arrive on the capture thread.
public final class MicrophoneAudio: AudioSource, @unchecked Sendable {
    private let capture: AudioCapture
    private let samples = Handler<[Float]>()
    private let failure = Handler<Error>()

    @MainActor
    public init(capture: AudioCapture? = nil) {
        self.capture = capture ?? AudioCapture()
        let samples = self.samples
        let failure = self.failure
        self.capture.onChunk = { chunk in samples(chunk.samples) }
        self.capture.onFailure = { error in failure(error) }
    }

    public var onSamples: (([Float]) -> Void)? {
        get { samples.handler }
        set { samples.handler = newValue }
    }

    public var onFailure: ((Error) -> Void)? {
        get { failure.handler }
        set { failure.handler = newValue }
    }

    public func start() throws {
        try MainActor.assumeIsolated { try capture.start() }
    }

    public func stop() {
        MainActor.assumeIsolated { capture.stop() }
    }

    public func close() {
        stop()
    }
}
