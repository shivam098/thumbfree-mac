import XCTest
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech
@testable import ThumbFreeApp

/// thumbfree-windows tests/ThumbFree.App.Tests/DictationHostTests.cs: the dictation host with the desktop, the
/// Accessibility API, the microphone and the models faked: what gets typed where, and when. (Its silent-microphone
/// case is in tests/ThumbFreeMacTests, with the Mac's SilenceWatch.)
final class DictationHostTests: XCTestCase {
    private static let chat = WindowInfo(handle: 42, processId: 7, processName: "WhatsApp", title: "Chat")

    private var folder: TempFolder!
    private var desktop: FakeDesktop!
    private var fields: FakeFields!
    private var audio: FakeAudio!
    private var models: FakeModels!
    private var downloads: FakeModelManager!
    private var surface: FakeSurface!
    private var services: AppServices!
    private var host: DictationHost!
    private var finished: Pending<DictationOutcome>!
    private let status = Locked<[StatusUpdate]>([])
    private let stopped = Locked<[Int]>([])

    override func setUp() {
        useTestBrowsers()
        folder = TempFolder()
        desktop = FakeDesktop()
        fields = FakeFields()
        audio = FakeAudio()
        models = FakeModels()
        downloads = FakeModelManager()
        surface = FakeSurface()
        services = TestServices.create(folder, models: downloads)

        // Shown at once, on any thread, as the Windows tests make theirs off the UI thread.
        services.notifier = Notifier(surface: surface, state: services.state, copy: { _ in }, queue: nil)
        desktop.window = Self.chat
        fields.field = DictationField(
            window: Self.chat, app: FakeFields.app(Self.chat), multiLine: true, textBefore: "", caretKnown: true,
            kind: "AXTextArea multi-line")
        host = DictationHost(
            services, models: models, post: { $0() }, desktop: desktop, fields: fields, audio: audio, sounds: false)
        let status = self.status
        let stopped = self.stopped
        let finished = Pending<DictationOutcome>()
        self.finished = finished
        host.onStatus = { update in status.update { $0.append(update) } }
        host.onCaptureStopped = { id in stopped.update { $0.append(id) } }
        host.onFinished = { outcome in finished.resolve(outcome) }
        host.start()
    }

    override func tearDown() {
        host.close()
        folder.remove()
    }

    func testStreamingTypesEachPhraseOnceTheNextOneHasStartedThenTheRestAtTheEnd() throws {
        models.session.script = { accepted in
            switch accepted {
            case ..<5: return ([], "hello there")
            case ..<10: return (["Hello there."], "how are")
            default: return (["Hello there.", "How are you?"], "I'm fine")
            }
        }
        models.session.final = ["Hello there.", "How are you?", "I'm fine"]

        host.beginDictationCapture(1)
        audio.speak(seconds: 1.2)
        waitFor { !self.desktop.typed.isEmpty }
        let typedWhileSpeaking = desktop.typed
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertEqual(typedWhileSpeaking, "Hello there.")
        XCTAssertEqual(desktop.typed, "Hello there. How are you? I'm fine.")
        XCTAssertTrue(outcome.typedAll)
        XCTAssertEqual(services.history.entries().map(\.text), ["Hello there. How are you? I'm fine."])
    }

    func testMovingToAnotherTextBoxTypesNothingMoreAndKeepsTheDictationToCopy() throws {
        models.session.script = { accepted in
            accepted < 5 ? (["Meet me at noon."], "then") : (["Meet me at noon.", "Bring the slides."], "")
        }
        models.session.final = ["Meet me at noon.", "Bring the slides.", "Thanks"]

        host.beginDictationCapture(1)
        audio.speak(seconds: 1.2)
        waitFor { !self.desktop.typed.isEmpty }
        fields.same = false
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertEqual(desktop.typed, "Meet me at noon.")
        XCTAssertTrue(outcome.kept)
        XCTAssertEqual(services.notifier?.untypedText, "Meet me at noon. Bring the slides. Thanks.")
        XCTAssertTrue(surface.shown.contains { $0.title == "Your dictation is safe" })
    }

    func testMovingToAPasswordBoxTypesNothingMoreAndKeepsTheDictationToCopy() throws {
        // Tab from a sign-in form's email box to its password box, or another window's: not this dictation's box.
        models.session.script = { accepted in
            accepted < 5 ? (["Meet me at noon."], "then") : (["Meet me at noon.", "Bring the slides."], "")
        }
        models.session.final = ["Meet me at noon.", "Bring the slides.", "Thanks"]

        host.beginDictationCapture(1)
        audio.speak(seconds: 1.2)
        waitFor { !self.desktop.typed.isEmpty }
        fields.same = false
        desktop.check = .password
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertEqual(desktop.typed, "Meet me at noon.")
        XCTAssertTrue(outcome.kept)
        XCTAssertEqual(services.notifier?.untypedText, "Meet me at noon. Bring the slides. Thanks.")
        XCTAssertEqual(services.history.entries().count, 1)
    }

    func testARefusalForAPasswordFieldDoesntCarryOverToTheNextDictation() throws {
        // A password field the first read missed: refused.
        let box = fields.field
        fields.field = nil
        desktop.check = .password
        let refused = try XCTUnwrap(host.dictate(["My secret words."], live: false).wait(timeout: 10))

        // Then an ordinary box, but ThumbFree's own window (its alert) comes to the front before it's typed.
        desktop.check = .safe
        let desktop = self.desktop!
        fields.reader = {
            desktop.window = nil
            return box
        }
        let outcome = try XCTUnwrap(host.dictate(["Hello there."], live: false).wait(timeout: 10))

        XCTAssertEqual(refused.problem, "password field")
        XCTAssertTrue(outcome.kept)
        XCTAssertEqual(services.notifier?.untypedText, "Hello there.")
    }

    func testAPasswordFieldStopsTheRecordingAndKeepsNothing() {
        services.settings.update { $0.saveSamples = true }
        fields.field?.password = true
        fields.field?.multiLine = false
        fields.field?.textBefore = nil
        models.session.script = { _ in (["my secret"], "") }
        models.session.final = ["my secret", "again"]

        host.beginDictationCapture(7)
        waitFor { self.stopped.value.contains(7) }
        audio.speak(seconds: 0.5)

        XCTAssertEqual(desktop.typed, "")
        XCTAssertTrue(services.history.entries().isEmpty)
        XCTAssertEqual(services.samples.summary().count, 0)
        XCTAssertEqual(status.value.filter { $0.message.contains("password") }.count, 1)
        XCTAssertFalse(audio.running)
    }

    func testAPasswordFieldTheFirstReadMissedIsRefusedWhenTypingAndNothingIsKept() {
        // A Chromium page that hadn't described itself, or an app too slow to answer: the read gives nothing, but the
        // check right before typing sees the password field.
        services.settings.update { $0.saveSamples = true }
        fields.field = nil
        desktop.check = .password
        models.session.script = { accepted in
            accepted < 5 ? (["My secret words."], "and") : (["My secret words.", "And more."], "")
        }
        models.session.final = ["My secret words.", "And more.", "Done"]

        host.beginDictationCapture(5)
        audio.speak(seconds: 1.2)
        waitFor { self.stopped.value.contains(5) }

        XCTAssertEqual(desktop.typed, "")
        XCTAssertFalse(audio.running)
        XCTAssertTrue(services.history.entries().isEmpty)
        XCTAssertEqual(services.samples.summary().count, 0)
        XCTAssertNil(services.notifier?.untypedText)
        XCTAssertNil(host.inserter.lastText)
        XCTAssertEqual(status.value.filter { $0.message.contains("password") }.count, 1)
    }

    func testAPasswordFieldFirstSeenWhenTheEndIsTypedKeepsNothing() throws {
        // Nothing was typed while speaking, so the check right before typing the end is the first to see it.
        services.settings.update { $0.saveSamples = true }
        fields.field = nil
        desktop.check = .password

        let outcome = try XCTUnwrap(host.dictate(["My secret words."], live: false).wait(timeout: 10))

        XCTAssertEqual(outcome.problem, "password field")
        XCTAssertEqual(desktop.typed, "")
        XCTAssertTrue(services.history.entries().isEmpty)
        XCTAssertEqual(services.samples.summary().count, 0)
        XCTAssertNil(services.notifier?.untypedText)
        XCTAssertNil(host.inserter.lastText)
    }

    func testAPrivateBrowserWindowKeepsNoHistoryEvenWhenItsBoxCantBeRead() throws {
        desktop.window = WindowInfo(
            handle: 43, processId: 8, processName: "Microsoft Edge", title: "New tab - [InPrivate] - Microsoft Edge")
        fields.field = nil
        models.session.script = { _ in ([], "private words") }
        models.session.final = ["Private words."]

        host.beginDictationCapture(1)
        audio.speak(seconds: 0.5)
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertTrue(outcome.typedAll)
        XCTAssertEqual(desktop.typed, "Private words.")
        XCTAssertTrue(services.history.entries().isEmpty)
    }

    func testTypingThatFailsTypesNothingMoreAndKeepsTheWholeDictationToCopy() throws {
        desktop.failure = TestError("The pasteboard is in use by another app.")
        models.session.script = { accepted in
            accepted < 5 ? (["Hello there."], "how are") : (["Hello there.", "How are you?"], "")
        }
        models.session.final = ["Hello there.", "How are you?", "I'm fine"]

        host.beginDictationCapture(1)
        audio.speak(seconds: 1.2)
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertEqual(desktop.typed, "")
        XCTAssertTrue(outcome.kept)
        XCTAssertEqual(services.notifier?.untypedText, "Hello there. How are you? I'm fine.")
        XCTAssertEqual(services.history.entries().map(\.text), ["Hello there. How are you? I'm fine."])
    }

    func testAScriptedDictationEndsEvenWhenTypingFails() throws {
        desktop.failure = TestError("The pasteboard is in use by another app.")

        let outcome = try XCTUnwrap(host.dictate(["Hello there."], live: false).wait(timeout: 10))

        XCTAssertTrue(outcome.kept)
    }

    /// The Mac's own: what PasteTyper refuses keeps the dictation to copy, and the notification says why.
    func testWhatTheTyperRefusesKeepsTheDictationAndSaysWhy() throws {
        let failures: [(PasteTyper.Failure, String)] = [
            (.notAllowed, "ThumbFree isn't allowed to type"),
            (.secureInput, "A password is being typed somewhere (Secure Input is on)"),
            (.secureInputUnknown, "ThumbFree couldn't tell whether a password is being typed"),
            (.pasteboardKeptChanging, "Something else kept being copied"),
        ]
        for (failure, reason) in failures {
            desktop.failure = failure

            let outcome = try XCTUnwrap(host.dictate(["Hello there."], live: false).wait(timeout: 10))

            XCTAssertTrue(outcome.kept, "\(failure)")
            XCTAssertEqual(services.notifier?.untypedText, "Hello there.", "\(failure)")
            let text = try XCTUnwrap(surface.shown.last?.text)
            XCTAssertTrue(text.hasPrefix(reason) && text.hasSuffix("Click to copy it."), text)
        }
    }

    func testTheTextBoxIsCheckedRightBeforeTypingAfterEverythingElse() throws {
        // The focus moves while the inserter checks the field (as when ⌘` is held while a phrase is typed).
        let fields = self.fields!
        desktop.onCheck = { fields.same = false }

        let outcome = try XCTUnwrap(host.dictate(["Hello there."], live: false).wait(timeout: 10))

        XCTAssertEqual(desktop.typed, "")
        XCTAssertTrue(outcome.kept)
    }

    func testTheTextBoxIsCheckedAgainOnceThePasteIsReady() throws {
        // The focus moves while the pasteboard is prepared.
        let fields = self.fields!
        desktop.whilePreparing = { fields.same = false }

        let outcome = try XCTUnwrap(host.dictate(["Hello there."], live: false).wait(timeout: 10))

        XCTAssertEqual(desktop.typed, "")
        XCTAssertTrue(outcome.kept)
    }

    func testAKeyHeldWhileTheBoxIsCheckedMeansItIsCheckedAgain() throws {
        // ⌘` pressed while the check runs: once the keys are let go, the next check sees the other window.
        let fields = self.fields!
        let held = Locked(true)
        desktop.modifierHeld = {
            var wasHeld = false
            held.update { value in
                wasHeld = value
                value = false
            }

            if wasHeld {
                fields.same = false
            }

            return wasHeld
        }

        let outcome = try XCTUnwrap(host.dictate(["Hello there."], live: false).wait(timeout: 10))

        XCTAssertEqual(desktop.typed, "")
        XCTAssertTrue(outcome.kept)
    }

    func testADictationStartedWhileTheLastOneTypesReadsItsBoxAgain() throws {
        // The box's text as it is when read; typing lands late, as it does after the key while it's let go.
        let desktop = self.desktop!
        let box = try XCTUnwrap(fields.field)
        fields.reader = {
            var read = box
            read.textBefore = desktop.typed
            return read
        }
        desktop.typeDelay = 0.3

        let first = host.dictate(["Hello there."], live: false)
        let second = host.dictate(["how are you?"], live: false)
        _ = try XCTUnwrap(first.wait(timeout: 10))
        _ = try XCTUnwrap(second.wait(timeout: 10))

        XCTAssertEqual(desktop.typed, "Hello there. How are you?")
    }

    func testADictationWhoseWindowWasLeftBeforeItsTurnToTypeKeepsItToCopy() throws {
        // Its box couldn't be told apart in its window (a Chromium page that hadn't described it yet), and the last
        // dictation was still typing. By this one's turn the focus is in another window's password box, which isn't
        // this dictation's. (The Mac reads such a box again before typing, so the first dictation reads it twice.)
        let fields = self.fields!
        let desktop = self.desktop!
        let reads = Locked(0)
        let box = Locked(try XCTUnwrap(fields.field))
        box.update { $0.isResolved = false }
        fields.reader = {
            reads.update { $0 += 1 }
            return box.value
        }
        desktop.afterTyping = {
            desktop.afterTyping = nil
            let deadline = Date().addingTimeInterval(5)
            while reads.value < 3 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }

            let bank = WindowInfo(handle: 43, processId: 8, processName: "Bank", title: "Sign in")
            desktop.window = bank
            desktop.check = .password
            fields.same = false
            box.update { field in
                field.window = bank
                field.password = true
            }
        }

        let first = host.dictate(["Hello there."], live: false)
        let second = host.dictate(["how are you?"], live: false)
        _ = try XCTUnwrap(first.wait(timeout: 10))
        let outcome = try XCTUnwrap(second.wait(timeout: 10))

        XCTAssertEqual(desktop.typed, "Hello there.")
        XCTAssertTrue(outcome.kept)
        XCTAssertNil(outcome.problem)
    }

    func testTheGuidesPracticeBoxGetsTheDictationAndTheAppInFrontGetsNothing() throws {
        let box = FakePracticeBox()
        services.practice.setActive(box)
        models.session.script = { accepted in
            accepted < 5 ? ([], "um things to do today") : (["Um, things to do today:"], "order groceries")
        }
        models.session.final = ["Um, things to do today:", "order groceries, go on a walk, and call mom"]

        host.beginDictationCapture(1)
        audio.speak(seconds: 1.2)
        waitFor { !box.live.isEmpty }
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertTrue(outcome.typedAll)
        XCTAssertEqual(box.inserted, "Things to do today: order groceries, go on a walk, and call mom.")
        XCTAssertEqual(desktop.typed, "")
    }

    func testAModelThatReReadsAudioTypesAPhraseAfterThePauseThatEndsTheNextOne() throws {
        services.settings.update { $0.englishTier = .standard }

        host.beginDictationCapture(1)
        audio.speak(seconds: 0.8, word: 0.3)
        audio.speak(seconds: 1.0, word: 0)
        audio.speak(seconds: 0.8, word: 0.5)
        audio.speak(seconds: 1.2, word: 0)
        waitFor { !self.desktop.typed.isEmpty }
        let typedWhileSpeaking = desktop.typed
        audio.speak(seconds: 0.8, word: 0.7)
        host.endDictationCapture(cancel: false)
        let outcome = try finishedOutcome()

        XCTAssertEqual(typedWhileSpeaking, "Hello there.")
        XCTAssertEqual(desktop.typed, "Hello there. How are you? I'm fine.")
        XCTAssertTrue(outcome.typedAll)
    }

    func testSwitchingLanguageAppliesAtOnceAndFetchesASmallModelThatIsMissing() {
        models.installed.update { _ = $0.remove(ModelCatalog.hinglish.id) }

        LanguageSwitch.toggle(services.settings)

        downloads.waitStarted(ModelCatalog.hinglish)
        XCTAssertTrue(status.value.contains { $0.message.contains("Hindi + English") })
        host.beginDictationCapture(3)
        XCTAssertTrue(stopped.value.contains(3))
        XCTAssertFalse(audio.running)
    }

    func testSwitchingLanguageKeepsTheModelChosenForEachLanguage() {
        services.settings.update { settings in
            settings.englishTier = .standard
            settings.hinglishTier = .accurate
        }

        LanguageSwitch.toggle(services.settings)
        XCTAssertEqual(services.current.selectedModel, ModelCatalog.hinglishAccurate)
        LanguageSwitch.toggle(services.settings)

        XCTAssertEqual(services.current.selectedModel, ModelCatalog.englishFast)
        XCTAssertEqual(services.current.hinglishTier, .accurate)
    }

    /// The Mac's own: its recognizers need a thread at least, whatever settings.json says, and Parakeet gets 4 at most.
    func testModelsLoadWithAtLeastOneThreadAndParakeetWithFourAtMost() throws {
        services.settings.update { $0.threads = 0 }
        try dictateWithTheMicrophone()
        services.settings.update { settings in
            settings.threads = 8
            settings.englishTier = .standard
        }
        let finished = Pending<DictationOutcome>()
        self.finished = finished
        host.onFinished = { outcome in finished.resolve(outcome) }
        try dictateWithTheMicrophone()

        XCTAssertEqual(models.threads.value, [1, 4])
    }

    private func dictateWithTheMicrophone() throws {
        host.beginDictationCapture(1)
        audio.speak(seconds: 0.3)
        host.endDictationCapture(cancel: false)
        _ = try finishedOutcome()
    }

    private func finishedOutcome(file: StaticString = #filePath, line: UInt = #line) throws -> DictationOutcome {
        try XCTUnwrap(finished.wait(timeout: 10), "the dictation didn't end", file: file, line: line)
    }
}

/// The desktop as the host types through it: typing is recorded, line breaks as "\n", and each step can be made to
/// move the focus, as the Windows tests' FakeDesktop does.
final class FakeDesktop: Desktop, GatedInput, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var typedText = ""
    private var foreground: WindowInfo?
    private var fieldCheck = FieldCheck.safe
    private var failing: Error?

    /// Runs during the inserter's field check.
    var onCheck: (() -> Void)?

    /// Runs while a paste is prepared, before the last check.
    var whilePreparing: (() -> Void)?

    /// Runs once text has landed.
    var afterTyping: (() -> Void)?

    /// Whether a modifier key is held right after a check (never, by default).
    var modifierHeld: () -> Bool = { false }

    /// How long a paste takes to land.
    var typeDelay: TimeInterval = 0

    var window: WindowInfo? {
        get { lock.withLock { foreground } }
        set { lock.withLock { foreground = newValue } }
    }

    /// What the inserter's own field check finds.
    var check: FieldCheck {
        get { lock.withLock { fieldCheck } }
        set { lock.withLock { fieldCheck = newValue } }
    }

    /// What typing throws, before anything is typed.
    var failure: Error? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    var typed: String { lock.withLock { typedText } }

    var modifiersDown: Bool { modifierHeld() }

    func foregroundWindow() -> WindowInfo? { window }

    func checkFocusedField() throws -> FieldCheck {
        onCheck?()
        return check
    }

    func focusedTextEndsWithNonWhitespace() -> Bool? { nil }

    func typeText(_ text: String) throws {
        try typeText(text, beforeKeys: {})
    }

    func typeText(_ text: String, beforeKeys: () throws -> Void) throws {
        if let failure {
            throw failure
        }

        whilePreparing?()
        try beforeKeys()
        if typeDelay > 0 {
            Thread.sleep(forTimeInterval: typeDelay)
        }

        lock.withLock { typedText += text }
        afterTyping?()
    }

    func pressKeys(_ chord: String) throws {
        try pressKeys(chord, beforeKeys: {})
    }

    func pressKeys(_ chord: String, beforeKeys: () throws -> Void) throws {
        whilePreparing?()
        try beforeKeys()
        lock.withLock { typedText += "\n" }
    }

    func waitForModifiers() {}
}

/// The focused box as the Accessibility API would read it.
final class FakeFields: FieldReader, @unchecked Sendable {
    private static let bundles = [
        "WhatsApp": "net.whatsapp.WhatsApp", "Microsoft Edge": "com.microsoft.edgemac", "Bank": "com.example.Bank",
    ]

    private let lock = NSLock()
    private var box: DictationField?
    private var reading: (() -> DictationField?)?
    private var focusStays = true

    var field: DictationField? {
        get { lock.withLock { box } }
        set { lock.withLock { box = newValue } }
    }

    /// Reads the box as it is at the time (instead of `field`).
    var reader: (() -> DictationField?)? {
        get { lock.withLock { reading } }
        set { lock.withLock { reading = newValue } }
    }

    /// The focus is still in the dictation's box.
    var same: Bool {
        get { lock.withLock { focusStays } }
        set { lock.withLock { focusStays = newValue } }
    }

    static func app(_ window: WindowInfo) -> TargetApp {
        TargetApp(name: window.processName, bundleIdentifier: bundles[window.processName])
    }

    func read(_ window: WindowInfo) -> DictationField? {
        if let reader {
            return reader()
        }

        return field
    }

    func readAgain(_ start: DictationField) -> DictationField? {
        same ? read(start.window) : nil
    }

    func isSameField(_ start: DictationField, _ now: WindowInfo?) -> Bool? { same }

    func app(of window: WindowInfo) -> TargetApp { Self.app(window) }
}

/// A microphone the test speaks into: 100 ms buffers in real time.
final class FakeAudio: AudioSource, @unchecked Sendable {
    private let handler = Locked<(([Float]) -> Void)?>(nil)
    private let isRunning = Locked(false)

    var onFailure: ((Error) -> Void)?

    var onSamples: (([Float]) -> Void)? {
        get { handler.value }
        set { handler.update { $0 = newValue } }
    }

    var running: Bool { isRunning.value }

    func start() throws {
        isRunning.update { $0 = true }
    }

    func stop() {
        isRunning.update { $0 = false }
    }

    func close() {
        stop()
    }

    /// Sound at `word`'s level (a fake word the fake recognizer reads back); 0 is a pause.
    func speak(seconds: Double, word: Float = 0.3) {
        var sent = 0.0
        while sent < seconds {
            if running {
                onSamples?([Float](repeating: word == 0 ? 0.0002 : word, count: 1600))
            }

            Thread.sleep(forTimeInterval: 0.1)
            sent += 0.1
        }
    }
}

/// Models that are all installed. The streaming session follows `FakeSession.script`; the others hear a word for
/// each level of sound (0.3 "Hello there.", 0.5 "How are you?", 0.7 "I'm fine."), and speech is anything louder than
/// 0.1.
final class FakeModels: SpeechModels, @unchecked Sendable {
    static let words = [3: "Hello there.", 5: "How are you?", 7: "I'm fine."]

    let installed = Locked(Set(ModelCatalog.all.map(\.id)))
    let session = FakeSession()

    /// The threads each model was loaded with.
    let threads = Locked<[Int]>([])

    func isInstalled(_ spec: ModelSpec) -> Bool { installed.value.contains(spec.id) }

    func load(_ spec: ModelSpec, threads: Int) throws -> Recognizer {
        self.threads.update { $0.append(threads) }
        return FakeRecognizer()
    }

    func startSession(_ model: Recognizer) throws -> LiveSession { session }

    func detectSpeech(_ audio: [Float]) throws -> [SpeechRegion] {
        var regions: [SpeechRegion] = []
        var start: Int?
        for i in 0...audio.count {
            let speech = i < audio.count && audio[i] > 0.1
            if speech && start == nil {
                start = i
            } else if !speech, let first = start {
                regions.append(SpeechRegion(start: Double(first) / 16_000, end: Double(i) / 16_000))
                start = nil
            }
        }

        return regions
    }

    func close() {}

    private final class FakeRecognizer: Recognizer, @unchecked Sendable {
        func transcribe(_ samples16k: [Float], preview: Bool, prompt: String?) -> String? {
            var levels: [Int] = []
            for sample in samples16k where sample > 0.1 {
                let level = Int((sample * 10).rounded(.toNearestOrEven))
                if !levels.contains(level) {
                    levels.append(level)
                }
            }

            return levels.map { FakeModels.words[$0] ?? "?" }.joined(separator: " ")
        }

        func abort() {}

        func resume() {}

        func close() {}
    }
}

/// A streaming dictation that says what `script` says for the chunks it has had.
final class FakeSession: LiveSession, @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = 0
    private var scripted: (Int) -> (finished: [String], partial: String) = { _ in ([], "") }
    private var finalPhrases: [String] = []

    var script: (Int) -> (finished: [String], partial: String) {
        get { lock.withLock { scripted } }
        set { lock.withLock { scripted = newValue } }
    }

    var final: [String] {
        get { lock.withLock { finalPhrases } }
        set { lock.withLock { finalPhrases = newValue } }
    }

    var finished: [String] { script(lock.withLock { accepted }).finished }

    var partial: String { script(lock.withLock { accepted }).partial }

    func accept(_ chunk: [Float]) {
        lock.withLock { accepted += 1 }
    }

    func finish() -> [String] { final }

    func close() {}
}

/// A practice box of the guide.
final class FakePracticeBox: PracticeTarget, @unchecked Sendable {
    let field = PracticeField(multiLine: true, atStart: true, email: false)

    private let liveTexts = Locked<[String?]>([])
    private let insertedText = Locked<String?>(nil)

    var live: [String?] { liveTexts.value }

    var inserted: String? { insertedText.value }

    func showLive(_ text: String?) {
        liveTexts.update { $0.append(text) }
    }

    func insert(_ text: String) {
        insertedText.update { $0 = text }
    }
}
