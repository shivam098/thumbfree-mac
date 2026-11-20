import CoreGraphics
import Foundation
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech

/// Where dictation audio comes from: the microphone (`MicrophoneAudio`), or a recording in tests (thumbfree-windows
/// `IAudioSource`).
public protocol AudioSource: AnyObject {
    /// Gets 16 kHz mono samples from -1 to 1, on the capture thread.
    var onSamples: (([Float]) -> Void)? { get set }

    /// Runs when capture stops by itself: the microphone was unplugged and there's no other one.
    var onFailure: ((Error) -> Void)? { get set }

    func start() throws

    func stop()

    /// Stops for good (C#'s Dispose).
    func close()
}

/// The text box a dictation is for, read when it starts (thumbfree-windows `FocusedField`): what kind of box it is,
/// the text before the cursor, the app it's in and how to recognise it again. `init(_:window:)` makes it from what
/// the Accessibility API read.
public struct DictationField: Sendable {
    /// The window in front when the dictation started. On the Mac it's the app in front.
    public var window: WindowInfo

    /// The app taking the keys, as History and samples record it.
    public var app: TargetApp

    public var password: Bool

    /// True or false when the box says so; nil when it doesn't (most chat apps), and then it's treated as one that
    /// takes line breaks.
    public var multiLine: Bool?

    public var search: Bool

    /// An email app or a webmail page: a greeting or a sign-off alone is enough for email layout.
    public var email: Bool

    /// A browser window that's private, or that can't be told apart from one (`PrivateWindows`): History leaves it out.
    public var privateWindow: Bool

    /// The text before the cursor (at most the last 2,000 UTF-16 units); nil when the box doesn't say.
    public var textBefore: String?

    /// False when only the end of the box's text could be read.
    public var caretKnown: Bool

    /// False while a web page hasn't described its box yet: it's read again (`FieldReader.readAgain`) before the first
    /// piece is typed.
    public var isResolved: Bool

    /// For logs: the kind of box, never its text or title.
    public var kind: String

    /// Its window's frame in Accessibility coordinates, for the pill.
    public var windowFrame: CGRect?

    /// What the Accessibility API read, to recognise the box again; nil for a box made in tests.
    public var focused: FocusedField?

    public init(
        window: WindowInfo,
        app: TargetApp,
        password: Bool = false,
        multiLine: Bool? = nil,
        search: Bool = false,
        email: Bool = false,
        privateWindow: Bool = false,
        textBefore: String? = nil,
        caretKnown: Bool = false,
        isResolved: Bool = true,
        kind: String = "",
        windowFrame: CGRect? = nil,
        focused: FocusedField? = nil
    ) {
        self.window = window
        self.app = app
        self.password = password
        self.multiLine = multiLine
        self.search = search
        self.email = email
        self.privateWindow = privateWindow
        self.textBefore = textBefore
        self.caretKnown = caretKnown
        self.isResolved = isResolved
        self.kind = kind
        self.windowFrame = windowFrame
        self.focused = focused
    }

    /// The box as the read found it, with the app and window rules (`FieldRules`, `PrivateWindows`) applied:
    /// thumbfree-windows `FocusInspector.Read`, on the Accessibility API's facts.
    public init(_ focused: FocusedField, window: WindowInfo) {
        let app = TargetApp(name: focused.app.name ?? "", bundleIdentifier: focused.app.bundleIdentifier)
        let email = !focused.isSearch && FieldRules.isEmail(app, title: focused.windowTitle)
        let privacy = PrivateWindows.reason(app, title: focused.windowTitle)
        self.init(
            window: window, app: app, password: focused.isSecure, multiLine: focused.takesLineBreaks,
            search: focused.isSearch, email: email, privateWindow: privacy != nil, textBefore: focused.textBefore,
            caretKnown: focused.caretKnown, isResolved: focused.isResolved,
            kind: focused.kind + (email ? " email" : "") + (privacy.map { " " + $0.rawValue } ?? ""),
            windowFrame: focused.windowFrame, focused: focused)
    }

    /// For the shared text rules. A box that doesn't say whether it takes line breaks is treated as one that does, as
    /// on Windows: "new line" presses the app's new-line keys (Shift+Enter in chat apps). Only boxes known to be
    /// single-line get spaces instead.
    public var fieldInfo: FieldInfo {
        FieldInfo(
            password: password, search: search, multiLine: multiLine ?? true, private: privateWindow, email: email)
    }
}

/// Which boxes get email layout, from the app and its window's title (the rules of thumbfree-windows `FocusInspector`,
/// by bundle identifier instead of process name). Its private-window rule is `PrivateWindows`.
public enum FieldRules {
    /// Mail, Outlook, Spark (classic and current), Thunderbird and eM Client, as Windows lists its email apps.
    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.readdle.sparkdesktop",
        "org.mozilla.thunderbird", "com.emclient.mail.client",
    ]

    static let webmailTitles = [
        "Gmail", "Outlook", "Proton Mail", "Yahoo Mail", "Zoho Mail", "Fastmail", "Superhuman", "Thunderbird", "Spark",
    ]

    /// An email app, or a browser showing webmail (its window's title says which).
    public static func isEmail(_ app: TargetApp, title: String?) -> Bool {
        if let id = app.bundleIdentifier, emailApps.contains(id.lowercased()) {
            return true
        }

        guard let title, Browsers.isBrowser(app.bundleIdentifier) else { return false }
        return webmailTitles.contains { DotNet.contains(title, $0) }
    }
}

/// The focused text box, through the Accessibility API (`MacFieldReader`); faked in tests (thumbfree-windows
/// `IFieldReader`). Its calls wait while the app answers, so the host makes them off the main thread.
public protocol FieldReader: AnyObject {
    /// The box with the keyboard focus, read when a dictation starts in `window`; nil when the Accessibility API can't
    /// tell in time.
    func read(_ window: WindowInfo) -> DictationField?

    /// The box with the focus now, read again, if it's `start`'s (for a box whose web page hadn't described it yet,
    /// the box in the same page or window); nil when the focus is somewhere else or it can't be read.
    func readAgain(_ start: DictationField) -> DictationField?

    /// The box with the focus now is `start`'s; nil when that can't be told in time, while `start`'s app is in front.
    func isSameField(_ start: DictationField, _ now: WindowInfo?) -> Bool?

    /// The app `window` belongs to, for History and samples when its box couldn't be read. Never waits.
    func app(of window: WindowInfo) -> TargetApp
}

/// The desktop's typing with a last check right before the keys go out: after the pasteboard holds the text and held
/// modifier keys are let go (thumbfree-windows `IGatedInput`; `MacDesktop` on the Mac). Faked in tests.
public protocol GatedInput: AnyObject {
    /// Types `text`; `beforeKeys` runs right before the keys, and stops them by throwing.
    func typeText(_ text: String, beforeKeys: () throws -> Void) throws

    /// Presses `chord`; `beforeKeys` runs right before, and stops it by throwing.
    func pressKeys(_ chord: String, beforeKeys: () throws -> Void) throws

    /// Waits (a second at most) until ⌘, ⌥, ⌃, ⇧ and Fn are let go.
    func waitForModifiers()

    /// ⌘, ⌥, ⌃, ⇧ or Fn is held now.
    var modifiersDown: Bool { get }
}

/// One streaming dictation (ThumbFreeSpeech's `StreamingRecognizer.Session`); faked in tests.
public protocol LiveSession: AnyObject {
    /// The phrases that ended at a pause, punctuated, in order.
    var finished: [String] { get }

    /// The phrase still being spoken.
    var partial: String { get }

    func accept(_ chunk: [Float])

    /// Flushes the last words and returns every phrase of the dictation.
    func finish() -> [String]

    func close()
}

/// The speech models dictation uses: which are on this Mac, and loading them (thumbfree-windows `ISpeechModels`).
/// Everything but `isInstalled` runs on the speech thread (`SpeechThread`).
public protocol SpeechModels: AnyObject {
    /// Every file the model needs is here, with the voice-activity model for the engines that use it.
    func isInstalled(_ spec: ModelSpec) -> Bool

    func load(_ spec: ModelSpec, threads: Int) throws -> Recognizer

    /// A streaming dictation on `model`, a streaming model from `load`.
    func startSession(_ model: Recognizer) throws -> LiveSession

    /// Where the audio has speech (Silero); all of it when the voice-activity model is missing.
    func detectSpeech(_ audio: [Float]) throws -> [SpeechRegion]

    /// Frees what it holds (C#'s Dispose).
    func close()
}

/// The model store's models, run with sherpa-onnx and whisper.cpp (thumbfree-windows `StoreSpeechModels`).
public final class StoreSpeechModels: SpeechModels, @unchecked Sendable {
    private let store: ModelStore
    private var detector: SpeechDetector?
    private var warned = false

    public init(_ store: ModelStore) {
        self.store = store
    }

    /// Whisper and Parakeet need Silero to find pauses: it cuts long dictation and ends phrases for live typing.
    /// `StoreModelManager` downloads it with them.
    public static func isInstalled(_ store: ModelStore, _ spec: ModelSpec) -> Bool {
        store.isInstalled(spec) && (spec.streaming || store.isInstalled(ModelCatalog.vad))
    }

    public func isInstalled(_ spec: ModelSpec) -> Bool { Self.isInstalled(store, spec) }

    public func load(_ spec: ModelSpec, threads: Int) throws -> Recognizer {
        try Recognizers.load(spec, from: store, threads: threads)
    }

    public func startSession(_ model: Recognizer) throws -> LiveSession {
        guard let streaming = model as? StreamingRecognizer else {
            throw SpeechError.invalidData("\(Swift.type(of: model)) isn't a streaming model.")
        }

        return KrokoSession(try streaming.startSession())
    }

    public func detectSpeech(_ audio: [Float]) throws -> [SpeechRegion] {
        if detector == nil, let path = store.pathOf(ModelCatalog.vad) {
            do {
                detector = try SpeechDetector(modelPath: path)
            } catch {
                Log.warn("voice activity model unusable: \(Log.kind(of: error))")
            }
        }

        guard let detector else {
            if !warned {
                warned = true
                Log.warn("no voice activity model: the whole recording counts as speech")
            }

            return [SpeechRegion(start: 0, end: Double(audio.count) / Double(Decoding.sampleRate))]
        }

        return try detector.detect(audio)
    }

    public func close() {
        detector?.close()
        detector = nil
    }

    private final class KrokoSession: LiveSession {
        private let session: StreamingRecognizer.Session

        init(_ session: StreamingRecognizer.Session) {
            self.session = session
        }

        var finished: [String] { session.finished }

        var partial: String { session.partial }

        func accept(_ chunk: [Float]) {
            session.accept(chunk)
        }

        func finish() -> [String] { session.finish() }

        func close() {
            session.close()
        }
    }
}
