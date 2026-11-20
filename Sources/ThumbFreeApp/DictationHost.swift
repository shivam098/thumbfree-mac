import CoreGraphics
import Foundation
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech

/// What happened to a dictation (for tests and logs).
public struct DictationOutcome: Equatable, Sendable {
    /// The whole dictation as laid out; empty when nothing was heard or it was refused.
    public var text: String
    /// Everything went into the text box it started in (or the guide's practice box).
    public var typedAll: Bool
    /// It went to the tap-to-copy notification instead: the box changed or didn't take the text.
    public var kept: Bool
    /// Why nothing more was typed (refused, nothing heard, recognition failed); nil otherwise.
    public var problem: String?

    public init(text: String, typedAll: Bool, kept: Bool, problem: String?) {
        self.text = text
        self.typedAll = typedAll
        self.kept = kept
        self.problem = problem
    }
}

/// Tap-to-dictate (PLAN 3.0), thumbfree-windows `DictationHost`: the dictation key opens the microphone, tapping it
/// again finishes, Esc cancels. The text box is chosen when dictation starts and text only ever goes there (3.6, 3.10
/// rule 1): finished phrases are typed at pauses while you speak (`LiveTyping`, the rules every platform shares), the
/// words not typed yet show in the pill, and the rest is typed when you finish. A dictation that can't go to its box
/// is kept for copying. Recognition runs on one speech thread (`SpeechThread`); field checks and typing run on one
/// serial queue, in order. "The UI thread" below is the main thread in the app (`post`).
public final class DictationHost: @unchecked Sendable {
    static let sampleRate = Decoding.sampleRate

    /// Streaming models get audio 100 ms at a time, as on Android.
    static let chunkSamples = sampleRate / 10

    static let levelInterval: TimeInterval = 0.05

    /// Models that aren't streaming re-read the newest audio this often while you speak (PLAN 3.10).
    static let previewInterval = DispatchTimeInterval.milliseconds(500)

    /// A pause this long ends a phrase, which is then transcribed once and can be typed (Kroko: 0.8 s).
    static let phrasePauseMs = 700

    static let passwordRefusal = "That's a password field — I won't type there."

    /// A model nobody has dictated with for this long is unloaded (PLAN 3.1).
    static let idleUnload: TimeInterval = 180

    private let services: AppServices
    private let desktop: Desktop
    private let guarded: GuardedDesktop
    private let fields: FieldReader
    private let audio: AudioSource
    private let speech: SpeechThread
    private let post: (@escaping () -> Void) -> Void
    private let soundsAllowed: Bool
    private let sounds: SoundFeedback
    private let queue = DispatchQueue(label: "app.thumbfree.mac.typing", qos: .userInitiated)
    private let lock = NSLock()
    private let shutdown = LockedValue(false)
    private let formatter: LockedValue<DictationFormatter>
    private let current = LockedValue<Dictation?>(nil)
    private let active = LockedValue(0)
    private let quitWaited = LockedValue(false)
    private var started = false
    private var idleWork: DispatchWorkItem?
    private var settingsToken: ObservationToken?

    /// Every dictation from its start to its end, by identity, for quitting (`finishForQuit`). Guarded by `lock`.
    private var inFlight: [ObjectIdentifier: Dictation] = [:]

    /// Capture thread only.
    private var lastLevelTime: TimeInterval = 0

    /// Typing queue only (and tests, once it's idle).
    private(set) var inserter: DictationInserter!

    private let status = Handler<StatusUpdate>()
    private let captureStopped = Handler<Int>()
    private let activity = Handler<String?>()
    private let inputLevel = Handler<Float>()
    private let preview = Handler<String?>()
    private let windowFrame = Handler<CGRect?>()
    private let finished = Handler<DictationOutcome>()

    /// - Parameters:
    ///   - post: Runs an action on the UI thread, later (the app: the main queue; tests run it at once).
    ///   - desktop: Typing and the field checks (`MacDesktop`).
    ///   - sounds: Play the start and stop tones when settings say so (off in tests).
    public init(
        _ services: AppServices,
        models: SpeechModels,
        post: @escaping (@escaping () -> Void) -> Void,
        desktop: Desktop,
        fields: FieldReader,
        audio: AudioSource,
        sounds: Bool
    ) {
        self.services = services
        self.post = post
        self.desktop = desktop
        guarded = GuardedDesktop(desktop)
        self.fields = fields
        self.audio = audio
        speech = SpeechThread(models)
        let settings = services.current
        soundsAllowed = sounds
        self.sounds = SoundFeedback(enabled: sounds && settings.soundFeedback)
        let formatter = Self.newFormatter(settings)
        self.formatter = LockedValue(formatter)
        queue.suspend()
        inserter = newInserter(formatter, lastText: nil)
        audio.onSamples = { [weak self] samples in self?.samplesArrived(samples) }
        audio.onFailure = { [weak self] error in self?.audioFailed(error) }
        settingsToken = services.settings.observe { [weak self] change in self?.settingsChanged(change) }
    }

    deinit {
        // A suspended queue mustn't be released.
        if !started {
            queue.resume()
        }
    }

    /// Runs on the UI thread with each status message.
    public var onStatus: ((StatusUpdate) -> Void)? {
        get { status.handler }
        set { status.handler = newValue }
    }

    /// Runs on the UI thread with the id given to `beginDictationCapture` when that recording couldn't start or stopped
    /// by itself (password field, time limit, microphone lost), so the keys stop acting as if recording.
    public var onCaptureStopped: ((Int) -> Void)? {
        get { captureStopped.handler }
        set { captureStopped.handler = newValue }
    }

    /// Runs on the UI thread with `DictationLabels.listening` or `DictationLabels.transcribing`; nil clears it.
    public var onActivity: ((String?) -> Void)? {
        get { activity.handler }
        set { activity.handler = newValue }
    }

    /// Runs on the UI thread about 20 times a second while recording, with the microphone level (0 to 1).
    public var onInputLevel: ((Float) -> Void)? {
        get { inputLevel.handler }
        set { inputLevel.handler = newValue }
    }

    /// Runs on the UI thread with the words said but not typed yet (nil clears them), for the pill.
    public var onPreview: ((String?) -> Void)? {
        get { preview.handler }
        set { preview.handler = newValue }
    }

    /// Runs on the UI thread with the frame of the window the dictation's box is in, once it's read, so the pill can
    /// go to that window's screen (the Mac's addition).
    public var onWindowFrame: ((CGRect?) -> Void)? {
        get { windowFrame.handler }
        set { windowFrame.handler = newValue }
    }

    /// Runs on the typing queue when a dictation is over.
    var onFinished: ((DictationOutcome) -> Void)? {
        get { finished.handler }
        set { finished.handler = newValue }
    }

    /// Starts the typing queue. Set the handlers first.
    public func start() {
        let starting: Bool = lock.withLock {
            defer { started = true }
            return !started
        }

        if starting {
            queue.resume()
        }
    }

    /// UI thread: starts recording for the text box that has the focus (or the guide's practice box). `id` names this
    /// recording in `onCaptureStopped`.
    public func beginDictationCapture(_ id: Int) {
        if current.value != nil {
            return
        }

        let settings = services.current
        let spec = settings.selectedModel
        if !speech.models.isInstalled(spec) {
            modelMissing(spec, openHome: true)
            reportCaptureStopped(id)
            return
        }

        // Windows refuses windows that run as administrator, where it may not type; a Mac has none.
        let practice = services.practice.active
        let window = practice == nil ? desktop.foregroundWindow() : nil
        let live = settings.liveTyping && (spec.streaming || spec.engine == .parakeet || spec.livePreview)
        let d = Dictation(
            id: id, spec: spec, settings: settings, formatter: formatter.value, window: window,
            app: window.map { fields.app(of: $0) }, practice: practice, live: live,
            previewSpec: previewModel(settings, spec, live: live))
        do {
            try audio.start()
        } catch {
            Log.error("microphone start failed: \(Log.kind(of: error))")
            report(.error, "Couldn't open the microphone. Check System Settings › Privacy & Security › Microphone.")
            reportCaptureStopped(id)
            return
        }

        current.value = d
        active.update { $0 += 1 }
        lock.withLock { inFlight[ObjectIdentifier(d)] = d }
        cancelIdleUnload()
        sounds.play(.startTyping)
        postActivity(DictationLabels.listening)
        var details = "\(spec.id), \(live ? "live typing" : "typed at the end")"
        if let preview = d.previewSpec {
            details += ", preview \(preview.id)"
        }

        if practice != nil {
            details += ", practice box"
        } else if window == nil {
            details += ", no window"
        }

        Log.info("dictation \(id): \(details)")
        if let window {
            d.typedAtRead = guarded.typed
            let fields = self.fields
            d.fieldRead = Pending<DictationField?>.run { fields.read(window) }
            d.fieldRead.then { [weak self] field in
                guard let self else { return }
                let frame = field?.windowFrame
                self.post { self.windowFrame(frame) }
                if field?.password == true {
                    self.post { self.refuse(d) }
                }
            }
        }

        speech.post { [self] in openSpeech(d) }
        if d.previewSpec != nil {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + Self.previewInterval, repeating: Self.previewInterval)
            timer.setEventHandler { [weak self] in self?.previewTick(d) }
            d.previewTimer = timer
            timer.resume()
        }
    }

    /// UI thread: stops recording; types the rest unless `cancel`.
    public func endDictationCapture(cancel: Bool) {
        if let d = current.value {
            stop(d, cancel: cancel, quiet: false)
        }
    }

    /// Types the last dictation again where the cursor is (the menu bar's "Paste last dictation").
    public func pasteLastTranscript() {
        enqueue { [self] in _ = try inserter.repeatLast() }
    }

    /// Tests: dictates `phrases` into the focused text box without a microphone or a model, each as if followed by a
    /// pause. With `live` they're typed as they come (live typing); without, at the end.
    func dictate(_ phrases: [String], live: Bool) -> Pending<DictationOutcome> {
        let window = desktop.foregroundWindow()
        let settings = services.current
        let d = Dictation(
            id: 0, spec: settings.selectedModel, settings: settings, formatter: formatter.value, window: window,
            app: window.map { fields.app(of: $0) }, practice: nil, live: live, previewSpec: nil)
        if let window {
            d.typedAtRead = guarded.typed
            let fields = self.fields
            d.fieldRead = Pending<DictationField?>.run { fields.read(window) }
        }

        active.update { $0 += 1 }
        lock.withLock { inFlight[ObjectIdentifier(d)] = d }
        let done = Pending<DictationOutcome>()
        enqueue { [self] in
            if live {
                for count in stride(from: 1, through: phrases.count, by: 1) {
                    d.gate.withLock { d.phrases = Array(phrases.prefix(count)) }
                    update(d)
                }
            }

            done.resolve(finish(d, Pending<[String]?>(phrases), []))
        }

        return done
    }

    /// Stops everything (C#'s Dispose): the recording, the queue (after what it's doing, 5 s at most, or a moment once
    /// `finishForQuit` has waited for it) and the models.
    public func close() {
        settingsToken?.cancel()
        if let d = current.value {
            d.stopped.value = true
            d.cancelled.value = true
            d.previewTimer?.cancel()
        }

        audio.stop()
        shutdown.value = true
        start()
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        if done.wait(timeout: .now() + (quitWaited.value ? 0.5 : 5)) == .timedOut {
            Log.warn("typing queue still busy at exit")
        }

        cancelIdleUnload()
        speech.close()
        audio.close()
        sounds.close()
    }

    /// A dictation is being recorded, transcribed or typed.
    public var isBusy: Bool { active.value > 0 }

    /// Quitting has something to see to (`finishForQuit`): a dictation being finished, or one that wasn't typed and is
    /// kept for copying.
    public var hasWorkForQuit: Bool { isBusy || services.notifier?.untypedText != nil }

    /// Quitting (`AppController`): the dictations already finishing get `timeout` to be transcribed and typed, as
    /// Windows types one in the moment it waits when it exits. They're waited for on another thread, so the main thread
    /// stays free: typing asks it about Secure Input. One whose text is known but isn't typed by then is kept, as a
    /// dictation whose box changed is. Then what wasn't typed is handed over (`handOverAtQuit`), and `whenDone` runs on
    /// the UI thread. Cancel a recording first: Windows drops one when it exits.
    public func finishForQuit(timeout: TimeInterval, then whenDone: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let deadline = Date(timeIntervalSinceNow: timeout)
            while active.value > 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }

            let left = keepUnfinished()
            quitWaited.value = true
            post { [self] in
                handOverAtQuit(left)
                whenDone()
            }
        }
    }

    /// UI thread, when ThumbFree quits with dictations that weren't typed: those `keepUnfinished` kept, and the one
    /// kept for copying (`Notifier.untypedText`), which would otherwise go with ThumbFree. What History doesn't have
    /// (it was off, the window was private, or the entry has gone since) goes on the pasteboard, which outlives
    /// ThumbFree, concealed from clipboard managers, since History may have left it out to keep it private. A
    /// notification, delivered first, says where they are.
    private func handOverAtQuit(_ left: [String]) {
        guard let notifier = services.notifier else { return }
        let kept = (notifier.untypedText.map { [$0] } ?? []) + left
        guard !kept.isEmpty else { return }
        let entries = services.history.entries()
        let notInHistory = kept.filter { text in !entries.contains { $0.text == text } }
        if !notInHistory.isEmpty {
            services.environment.copyText(notInHistory.joined(separator: "\n\n"), concealed: true)
        }

        notifier.showKeptAtQuit(onPasteboard: !notInHistory.isEmpty)
        notifier.waitForDelivery(timeout: 1)
    }

    /// When ThumbFree quits: the dictations whose text is known but isn't typed yet are kept (History, unless it leaves
    /// them out, and samples), and nothing more of them is typed. Returns their text.
    private func keepUnfinished() -> [String] {
        let dictations = lock.withLock { Array(inFlight.values) }.sorted { $0.startTime < $1.startTime }
        var left: [String] = []
        for d in dictations where !d.refused.value {
            guard let end = d.gate.withLock({ d.end }) else {
                if !d.cancelled.value {
                    Log.warn("dictation \(d.id): ThumbFree quit before it was transcribed")
                }

                continue
            }

            if d.kept.exchange(true) {
                continue
            }

            Log.warn("dictation \(d.id): ThumbFree quit before it was typed; kept")
            keep(d, end)
            left.append(end.text)
        }

        return left
    }

    /// The model that re-reads the newest audio while you speak (for live typing, or only for the pill), or nil.
    /// Streaming models report their text themselves; with Live typing off nothing re-reads audio (PLAN 3.10, rule
    /// 8). The accurate Hindi + English model takes seconds per pass, so the standard one previews for it when it's
    /// here.
    private func previewModel(_ settings: AppSettings, _ spec: ModelSpec, live: Bool) -> ModelSpec? {
        if !settings.liveTyping || spec.streaming {
            return nil
        }

        if live {
            return spec
        }

        let hinglish = ModelCatalog.hinglish
        return spec.language == .hinglish && spec.id != hinglish.id && speech.models.isInstalled(hinglish)
            ? hinglish : nil
    }

    /// UI thread: the chosen model isn't on this Mac. Small models download straight away; big ones ask first (the
    /// menu bar).
    private func modelMissing(_ spec: ModelSpec, openHome: Bool) {
        let models = services.models
        let state = models.state(spec)
        if state.status == .downloading {
            let percent = Int(state.progress * 100)
            report(.info, "The speech model is still downloading (\(percent)%). Try again when it's done.")
        } else if !ModelConsent.needed(spec) {
            models.start(spec)
            report(.info, "Downloading the speech model (one time; it stays on this Mac). Try again in a moment.")
        } else {
            report(.warning, "Download “\(ModelConsent.shortName(spec))” first, from ThumbFree's menu bar.")
            if openHome {
                services.openPage(.home)
            }
        }
    }

    /// UI thread: the dictation's text box is a password field: stop, and keep nothing.
    private func refuse(_ d: Dictation) {
        if !d.refusalShown.exchange(true) {
            report(.warning, Self.passwordRefusal)
        }

        d.refused.value = true
        if current.value === d {
            reportCaptureStopped(d.id)
            stop(d, cancel: true, quiet: true)
        }
    }

    /// UI thread: stops recording `d`, then finishes it unless `cancel`.
    private func stop(_ d: Dictation, cancel: Bool, quiet: Bool) {
        guard current.value === d else { return }
        current.value = nil
        d.stopped.value = true
        d.previewTimer?.cancel()
        audio.stop()
        if d.gate.withLock({ d.silence.isSilent }) {
            services.notifier?.clearMicrophoneSilent()
        }

        sounds.play(cancel ? .standby : .stopTyping)
        showPreview(nil)
        d.practice?.showLive(nil)
        if cancel {
            d.cancelled.value = true
            postActivity(nil)
            speech.post { [self] in closeSpeech(d) }
            if !quiet {
                report(
                    .info,
                    d.typedAny.value ? "Dictation cancelled. The words already typed stay." : "Dictation cancelled.")
            }

            done(d)
            return
        }

        postActivity(DictationLabels.transcribing)
        let recording = d.gate.withLock { d.audio }
        let phrases = speech.run { [self] in finishSpeech(d, recording) }
        enqueue { [self] in _ = finish(d, phrases, recording) }
    }

    /// The recording reached `AppSettings.maxDictationSeconds`: finish it as if the key was tapped.
    private func finishAtLimit(_ d: Dictation, _ seconds: Int) {
        guard current.value === d else { return }
        Log.info("dictation reached the \(seconds)s limit")
        reportCaptureStopped(d.id)
        stop(d, cancel: false, quiet: true)
        let limit = seconds % 60 == 0
            ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
        report(.info, "Dictation stops by itself after \(limit). Tap \(keyName) to keep going.")
    }

    private func audioFailed(_ error: Error) {
        Log.error("microphone stopped: \(Log.kind(of: error))")
        post { [self] in
            guard let d = current.value else { return }

            // PLAN 3.6: write what was said so far, and say so.
            reportCaptureStopped(d.id)
            services.notifier?.showInterrupted()
            report(.warning, "The microphone stopped. What you said so far is being written.")
            stop(d, cancel: false, quiet: true)
        }
    }

    /// Capture thread.
    private func samplesArrived(_ samples: [Float]) {
        guard let d = current.value, !d.stopped.value else { return }
        let (total, fed, silenceChanged, silent): (Int, Int, Bool, Bool) = d.gate.withLock {
            d.audio.append(contentsOf: samples)
            let changed = d.silence.add(samples)
            return (d.audio.count, d.fed, changed, d.silence.isSilent)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelTime >= Self.levelInterval {
            lastLevelTime = now
            let level = AudioLevel.of(samples)
            post { [self] in inputLevel(level) }
        }

        if silenceChanged {
            if silent {
                Log.warn("microphone sends only silence")
                services.notifier?.showMicrophoneSilent()
                report(.warning, "No sound from the microphone. Is another app or a call using it?")
            } else {
                services.notifier?.clearMicrophoneSilent()
            }
        }

        if d.spec.streaming && d.ready.value && total - fed >= Self.chunkSamples && !d.feedQueued.exchange(true) {
            speech.post { [self] in feed(d) }
        }

        let limit = services.current.maxDictationSeconds
        if limit > 0 && !d.limitReached.value && total >= limit * Self.sampleRate {
            d.limitReached.value = true
            post { [self] in finishAtLimit(d, limit) }
        }
    }

    /// Timer thread: asks the speech thread to re-read the newest audio, unless it's still busy with the last pass.
    private func previewTick(_ d: Dictation) {
        guard !d.stopped.value, d.ready.value else { return }
        let pending: Int? = d.gate.withLock { d.hasPreview ? d.audio.count - d.committed : nil }
        if let pending, pending >= Self.sampleRate / 2, !d.previewBusy.exchange(true) {
            speech.post { [self] in try reread(d) }
        }
    }

    // MARK: Speech thread

    /// Loads the model (audio is recorded meanwhile) and opens the streaming session or the live preview.
    private func openSpeech(_ d: Dictation) {
        if d.cancelled.value {
            return
        }

        do {
            let model = try speech.model(d.spec, threads: threads(d.spec), keep: d.previewSpec)
            model.resume()
            if d.spec.streaming {
                d.session = try speech.models.startSession(model)
            } else if let previewSpec = d.previewSpec {
                let previewModel = try previewSpec.id == d.spec.id
                    ? model : speech.model(previewSpec, threads: threads(previewSpec), keep: d.spec)
                previewModel.resume()
                let previewPrompt = previewSpec.promptVocabulary ? d.prompt : nil
                let models = speech.models
                var commit: (([Float]) async throws -> String)?
                if d.live {
                    commit = { audio in
                        try Self.prepare(d, model.transcribe(audio, preview: false, prompt: d.prompt), audio.count)
                    }
                }

                d.preview = DictationPreview(
                    transcribe: { audio in
                        try Self.prepare(
                            d, previewModel.transcribe(audio, preview: true, prompt: previewPrompt), audio.count)
                    },
                    detect: { audio in try models.detectSpeech(audio) },
                    sampleRate: Self.sampleRate,
                    phrasePauseMs: d.live ? Self.phrasePauseMs : nil,
                    commit: commit)
                d.gate.withLock { d.hasPreview = true }
            }

            d.ready.value = true
            if d.session != nil {
                feed(d)
            }
        } catch {
            Log.error("model \(d.spec.id) didn't load: \(Log.kind(of: error))")
            d.loadFailed.value = true
            post { [self] in
                report(
                    .error,
                    "Couldn't load the speech model. Delete it from ThumbFree's models folder, then download it again.")
                if current.value === d {
                    reportCaptureStopped(d.id)
                    stop(d, cancel: true, quiet: true)
                }
            }
        }
    }

    /// Gives the streaming session the audio recorded since the last time, 100 ms at a time.
    private func feed(_ d: Dictation) {
        d.feedQueued.value = false
        guard let session = d.session, !d.cancelled.value else { return }
        let fresh: [Float] = d.gate.withLock {
            let unheard = Array(d.audio[d.fed...])
            d.fed = d.audio.count
            return unheard
        }

        for start in stride(from: 0, to: fresh.count, by: Self.chunkSamples) {
            session.accept(Array(fresh[start..<min(fresh.count, start + Self.chunkSamples)]))
        }

        let finished = session.finished
        let partial = Self.prepare(d, session.partial, 0)
        d.gate.withLock {
            for phrase in finished.dropFirst(d.phrases.count) {
                d.phrases.append(Self.prepare(d, phrase, 0))
            }

            d.partial = partial
        }

        scheduleUpdate(d)
    }

    /// Re-reads the audio after the last finished phrase (models that aren't streaming).
    private func reread(_ d: Dictation) throws {
        defer { d.previewBusy.value = false }
        guard !d.stopped.value, let preview = d.preview else { return }
        let pending: [Float] = d.gate.withLock { Array(d.audio[min(d.committed, d.audio.count)...]) }
        try Self.blocking { _ = try await preview.update(pending) }
        d.gate.withLock {
            d.committed = preview.committedSamples
            if d.live {
                d.phrases = preview.phrases
                d.partial = preview.tentative
            } else {
                // Only the pill: the model that types reads everything once you finish.
                d.partial = LiveText.join(preview.phrases, preview.tentative)
            }
        }

        scheduleUpdate(d)
    }

    /// The dictation's phrases once recording stops: every phrase typed or shown before, then the rest. Nil when the
    /// speech couldn't be recognized. A streaming session already heard everything; other models transcribe the audio
    /// after the last finished phrase, cut at pauses into pieces they can take (14 s for Whisper, 30 s for Parakeet).
    private func finishSpeech(_ d: Dictation, _ audio: [Float]) -> [String]? {
        if d.loadFailed.value || d.refused.value || !d.ready.value {
            return nil
        }

        do {
            if let session = d.session {
                feed(d)
                let all = session.finish()
                session.close()
                d.session = nil
                let phrases: [String] = d.gate.withLock {
                    for phrase in all.dropFirst(d.phrases.count) {
                        d.phrases.append(Self.prepare(d, phrase, 0))
                    }

                    // The last phrase, cut at a pause, may end in a comma: the end of a dictation ends a sentence (as
                    // on Android).
                    var ended = d.phrases
                    if let last = ended.lastIndex(where: { !d.formatter.format($0).isEmpty }) {
                        ended[last] = LiveText.endSentence(ended[last])
                    }

                    return ended
                }

                return phrases
            }

            let model = try speech.model(d.spec, threads: threads(d.spec), keep: d.previewSpec)
            model.resume()
            var result: [String] = []
            var from = 0
            if d.live, let preview = d.preview {
                result += preview.phrases
                from = min(preview.committedSamples, audio.count)
            }

            d.preview = nil
            let tail = Array(audio[from...])
            let maxMs = d.spec.maxPieceSamples * 1000 / Self.sampleRate
            let speechRegions = try speech.models.detectSpeech(tail)
            for piece in SpeechSegments.chunk(
                tail, speechRegions, sampleRate: Self.sampleRate, maxMs: maxMs, padMs: 200) {
                guard let text = try model.transcribe(piece, preview: false, prompt: d.prompt) else { return nil }
                result.append(Self.prepare(d, text, piece.count))
            }

            return result
        } catch {
            Log.error("recognition failed: \(Log.kind(of: error))")
            return nil
        }
    }

    private func closeSpeech(_ d: Dictation) {
        d.session?.close()
        d.session = nil
        d.preview = nil
    }

    private func unloadIfIdle() {
        if active.value == 0 {
            speech.unloadAll()
        }
    }

    // MARK: Typing queue: the field, typing, the end of each dictation

    private func scheduleUpdate(_ d: Dictation) {
        if !d.updateQueued.exchange(true) {
            enqueue { [self] in update(d) }
        }
    }

    /// Types the phrases that are final and shows the rest in the pill (or the practice box).
    private func update(_ d: Dictation) {
        d.updateQueued.value = false
        if d.stopped.value && d.id != 0 {
            // The end of the dictation types everything still to type, laid out.
            return
        }

        let (phrases, partial) = d.gate.withLock { (d.phrases, d.partial) }
        if let box = d.practice {
            let words = d.formatter.format(LiveText.join(phrases, partial))
            box.showLive(words.isEmpty ? nil : words)
            return
        }

        guard let typing = liveTyping(d), !(d.stopped.value && d.id != 0) else { return }
        var step = typing.update(phrases, partial)
        if !step.type.isEmpty && d.provisional {
            // The first piece is about to be typed into a web page's box that hadn't described itself: it's read again
            // now, and the dictation laid out for it, since nothing has been typed yet.
            guard let resolved = resolveBeforeTyping(d) else {
                showPreview(nil)
                return
            }

            if resolved !== typing {
                step = resolved.update(phrases, partial)
            }
        }

        showPreview(step.pending)
        if !step.type.isEmpty {
            typeIntoField(d, step.type)
        }
    }

    /// The live typing of `d`, once its text box is known (read through the Accessibility API when it started). Nil
    /// for a password field, which refuses the dictation.
    private func liveTyping(_ d: Dictation) -> LiveTyping? {
        if d.typing != nil || d.refused.value {
            return d.typing
        }

        var field = d.fieldRead.wait() ?? nil
        if let start = field, !start.isResolved {
            // A web page that hadn't described its box when the dictation started (the Mac's Chromium and Electron
            // apps do it about 2 s after they're woken): the live typing is provisional until the box is read again,
            // right before the first piece is typed (`resolveBeforeTyping`).
            d.provisional = true
        } else if let start = field, let window = d.window, guarded.typed != d.typedAtRead,
                  desktop.foregroundWindow()?.handle == window.handle {
            // Typing since the box was read (the end of the previous dictation) changed the text before the cursor:
            // read it again, now that this dictation's turn to type has come, if its app is still in front.
            if let again = fields.readAgain(start) {
                Log.info("dictation \(d.id): text before the cursor read again after typing")
                var merged = start
                merged.textBefore = again.textBefore
                merged.caretKnown = again.caretKnown
                merged.password = start.password || again.password
                field = merged
            }
        }

        d.field = field

        // A box the Accessibility API can't read is treated as one that takes line breaks, as on Windows: "new line"
        // presses the app's new-line keys (Shift+Enter in chat apps). Its window's title isn't known then, so in a
        // browser it counts as a private window, which History leaves out (`PrivateWindows`).
        d.info = field?.fieldInfo
            ?? FieldInfo(multiLine: true, private: d.app.map { PrivateWindows.mayBePrivate($0, title: nil) } ?? false)
        if d.info.password {
            refuseLive(d)
            return nil
        }

        if d.window == nil {
            detach(d, "There was no text box to type into.")
        }

        let before = field?.textBefore.map { ", \($0.utf16.count) chars before" } ?? ""
        let kind = field?.kind ?? (d.info.private ? "unknown, private-no-title" : "unknown")
        Log.info("dictation \(d.id) field: \(kind)\(before)")
        let typing = newLiveTyping(d, field)
        d.typing = typing
        return typing
    }

    /// Right before the first piece is typed into a web page's box that hadn't described itself when the dictation
    /// started: the box is read again and, once it's there, the live typing starts over for it (the text before the
    /// cursor, whether it takes line breaks, and the box itself for the same-box check). Nothing has been typed, so
    /// nothing changes on the screen. Nil for a password box, which refuses the dictation.
    private func resolveBeforeTyping(_ d: Dictation) -> LiveTyping? {
        guard d.provisional, let start = d.field else { return d.typing }
        d.provisional = false
        guard let resolved = fields.readAgain(start) else {
            Log.info("dictation \(d.id): the web page still hasn't described its box; typing into the page")
            return d.typing
        }

        Log.info("dictation \(d.id): the web page's box read once it was described: \(resolved.kind)")
        d.field = resolved
        d.info = resolved.fieldInfo
        if d.info.password {
            d.typing = nil
            refuseLive(d)
            return nil
        }

        let typing = newLiveTyping(d, resolved)
        d.typing = typing
        return typing
    }

    private func newLiveTyping(_ d: Dictation, _ field: DictationField?) -> LiveTyping {
        LiveTyping(
            d.formatter,
            LiveTypingContext(textBefore: field?.textBefore, field: d.info, live: d.live, smartFormatting: d.smart))
    }

    /// The dictation's box turned out to be a password field, read on the typing queue: it's refused, and its
    /// recording stops, as for one found when it started (`refuse` says so once).
    private func refuseLive(_ d: Dictation) {
        d.refused.value = true
        post { [self] in refuse(d) }
    }

    /// Types into the dictation's own text box only. The box is checked right before each paste or key press, after
    /// any held modifier keys are let go (`GuardedDesktop`): a different window or box detaches the dictation (PLAN
    /// 3.6). A password field that the read at the start missed refuses it, and then nothing of it is kept; that's
    /// decided only when the password field is the dictation's own box, or in its app when the box couldn't be told
    /// apart. A password box somewhere else detaches it like any other box, so it's kept to copy.
    @discardableResult
    private func typeIntoField(_ d: Dictation, _ text: String) -> Bool {
        if d.detachReason != nil || d.refused.value || text.isEmpty {
            return false
        }

        guarded.sameField = { [unowned self] in self.sameField(d) }
        guarded.resetCheck()
        defer { guarded.sameField = nil }
        do {
            if try inserter.typePrepared(text, d.info) {
                d.typedAny.value = true
                return true
            }

            if guarded.lastCheck == .password {
                // The inserter has said so already.
                _ = d.refusalShown.exchange(true)
                d.refused.value = true
                post { [self] in refuse(d) }
                return false
            }

            detach(d, "The text box didn't take it.")
            return false
        } catch is FieldChanged {
            let reason = d.kept.value
                ? "ThumbFree quit before it was typed."
                : "You moved to another window or text box, so it wasn't typed there."
            detach(d, reason)
            return false
        } catch {
            Log.error("typing failed: \(Log.kind(of: error))")
            detach(d, Self.reason(error))
            return false
        }
    }

    /// Why typing failed, in a sentence for the pill and the notification: what PasteTyper says, else that the box
    /// didn't take it.
    static func reason(_ error: Error) -> String {
        if error is MacDesktop.UnknownKeys {
            return "This app's new-line keys in settings.json aren't keys ThumbFree knows."
        }

        switch error as? PasteTyper.Failure {
        case .notAllowed?:
            return "ThumbFree isn't allowed to type: turn it on in System Settings › Privacy & Security › "
                + "Accessibility."
        case .secureInput?:
            return "A password is being typed somewhere (Secure Input is on), so it wasn't typed."
        case .secureInputUnknown?:
            return "ThumbFree couldn't tell whether a password is being typed, so it wasn't typed."
        case .pasteboardKeptChanging?:
            return "Something else kept being copied, so it wasn't pasted."
        default:
            return "The text box didn't take it."
        }
    }

    /// The dictation's text box has the focus (or it can't be told in time while its app is in front). Never once
    /// quitting has kept the dictation (`keepUnfinished`), so nothing more of it is typed.
    private func sameField(_ d: Dictation) -> Bool {
        if d.kept.value {
            return false
        }

        let now = desktop.foregroundWindow()
        let same: Bool?
        if let field = d.field {
            same = fields.isSameField(field, now)
        } else if let now, let window = d.window {
            same = now.handle == window.handle
        } else {
            same = false
        }

        if same == nil {
            Log.info("same-field check timed out in the same app; typing")
        }

        return same != false
    }

    private func detach(_ d: Dictation, _ reason: String) {
        if d.detachReason == nil {
            d.detachReason = reason
            Log.info("dictation \(d.id): nothing more is typed (\(reason))")
        }
    }

    /// The end of a dictation: types the rest into its text box (or the practice box), or keeps it for copying, then
    /// History and samples.
    private func finish(_ d: Dictation, _ recognized: Pending<[String]?>, _ audio: [Float]) -> DictationOutcome {
        var outcome = DictationOutcome(text: "", typedAll: false, kept: false, problem: "stopped")
        defer {
            if current.value == nil {
                postActivity(nil)
            }

            done(d)
            finished(outcome)
        }

        // Nil when ThumbFree is shutting down.
        guard let result = recognized.wait() else { return outcome }
        if d.refused.value {
            outcome.problem = "password field"
            return outcome
        }

        guard let phrases = result else {
            let message = d.typedAny.value
                ? "Couldn't transcribe the rest. The words already typed stay." : "Couldn't transcribe that. Try again."
            report(.error, message)
            outcome.problem = "recognition failed"
            return outcome
        }

        let raw = LiveText.join(phrases, "")
        if let box = d.practice {
            let practiced = d.formatter.format(raw)
            if practiced.isEmpty {
                report(.info, "I didn't catch anything.")
                outcome.problem = "nothing heard"
                return outcome
            }

            box.insert(practiced)
            d.kept.value = true
            keep(d, Dictation.Ending(audio: audio, raw: raw, text: practiced, info: d.info, app: nil))
            report(.success, "Typed.", heard: practiced)
            outcome = DictationOutcome(text: practiced, typedAll: true, kept: false, problem: nil)
            return outcome
        }

        guard var typing = liveTyping(d) else {
            if !d.refusalShown.exchange(true) {
                report(.warning, Self.passwordRefusal)
            }

            outcome.problem = "password field"
            return outcome
        }

        var rest = typing.finish(phrases)
        if d.provisional && !rest.isEmpty {
            // Nothing was typed while speaking: the end is the first piece, so the web page's box is read again now.
            guard let resolved = resolveBeforeTyping(d) else {
                if !d.refusalShown.exchange(true) {
                    report(.warning, Self.passwordRefusal)
                }

                outcome.problem = "password field"
                return outcome
            }

            if resolved !== typing {
                typing = resolved
                rest = typing.finish(phrases)
            }
        }

        let text = typing.finalText
        if text.isEmpty {
            report(.info, "I didn't catch anything.")
            outcome.problem = "nothing heard"
            return outcome
        }

        if typing.phrasesChanged {
            detach(d, "The words changed after some were typed.")
        } else if typing.finishedWithoutLayout {
            Log.info("dictation \(d.id): typed without the final layout (it would have changed typed words)")
        }

        // What quitting keeps if this isn't typed in time (`keepUnfinished`).
        let ending = Dictation.Ending(audio: audio, raw: raw, text: text, info: d.info, app: d.field?.app ?? d.app)
        d.gate.withLock { d.end = ending }
        if !rest.isEmpty {
            typeIntoField(d, rest)
        }

        if d.refused.value {
            // A password field after all: nothing is offered for copying or kept.
            d.gate.withLock { d.end = nil }
            outcome.problem = "password field"
            return outcome
        }

        if d.kept.exchange(true) {
            // ThumbFree was quitting, and kept it before it could be typed.
            outcome = DictationOutcome(text: text, typedAll: false, kept: true, problem: nil)
            return outcome
        }

        if let reason = d.detachReason {
            inserter.lastText = text
            services.notifier?.showUntyped(text, reason: reason)
            let copy = services.environment.notificationsEnabled()
                ? "click its notification, or choose Copy the text that wasn't typed in the menu bar"
                : "choose Copy the text that wasn't typed in the menu bar"
            report(.warning, "\(reason) Your dictation is safe: \(copy).")
            outcome = DictationOutcome(text: text, typedAll: false, kept: true, problem: nil)
        } else {
            inserter.lastText = typing.text
            report(.success, "Typed.", heard: typing.text)
            outcome = DictationOutcome(text: text, typedAll: true, kept: false, problem: nil)
        }

        keep(d, ending)
        return outcome
    }

    /// History (never from password fields, nor from private windows or browser windows that can't be told apart from
    /// them: `PrivateWindows`) and, when opted in, a sample (never from password fields or web browsers:
    /// `SampleStore`).
    private func keep(_ d: Dictation, _ ending: Dictation.Ending) {
        if !ending.info.private {
            services.history.add(ending.text, app: ending.app?.name, passwordField: ending.info.password)
        }

        services.samples.save(
            ending.audio, recognized: ending.raw, typed: ending.text, model: d.spec,
            passwordField: ending.info.password || ending.info.private, app: ending.app)
    }

    private func done(_ d: Dictation) {
        lock.withLock { _ = inFlight.removeValue(forKey: ObjectIdentifier(d)) }
        let left: Int = active.update { count in
            count -= 1
            return count
        }

        if left == 0 && !shutdown.value {
            scheduleIdleUnload()
        }
    }

    private func scheduleIdleUnload() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.speech.post { [weak self] in self?.unloadIfIdle() }
        }

        lock.withLock {
            idleWork?.cancel()
            idleWork = work
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleUnload, execute: work)
    }

    private func cancelIdleUnload() {
        lock.withLock {
            idleWork?.cancel()
            idleWork = nil
        }
    }

    // MARK: Settings

    /// UI thread: settings apply straight away; a dictation already going keeps what it started with. The insert
    /// method needs nothing here: `MacDesktop` reads it before each piece.
    private func settingsChanged(_ change: SettingsChange) {
        let settings = services.current
        if change.has(.removeFillerWords, .spokenPunctuation, .replacements, .snippets, .newLineKeys) {
            let formatter = Self.newFormatter(settings)
            self.formatter.value = formatter
            enqueue { [self] in inserter = newInserter(formatter, lastText: inserter.lastText) }
        }

        if change.has(.soundFeedback) {
            sounds.enabled = soundsAllowed && settings.soundFeedback
        }

        if change.has(.language) {
            report(
                .info,
                settings.language == .hinglish
                    ? "Dictation language: Hindi + English (Hindi is typed in Roman letters)."
                    : "Dictation language: English.")
        }

        if change.has(.language, .englishTier, .hinglishTier, .threads) {
            if !speech.models.isInstalled(settings.selectedModel) {
                modelMissing(settings.selectedModel, openHome: false)
            }

            // The next dictation loads the model chosen now; the old one goes if nothing is using it.
            speech.post { [self] in unloadIfIdle() }
        }
    }

    private static func newFormatter(_ settings: AppSettings) -> DictationFormatter {
        DictationFormatter(settings.dictationOptions)
    }

    private func newInserter(_ formatter: DictationFormatter, lastText: String?) -> DictationInserter {
        let keys = services.current.newLineKeys.pairs.map { (process: $0.key, keys: $0.value) }
        let inserter = DictationInserter(guarded, formatter, newLineKeysByProcess: keys)
        inserter.lastText = lastText
        let status = self.status
        let post = self.post
        inserter.onStatus = { update in post { status(update) } }
        return inserter
    }

    /// Parakeet runs fastest on 4 threads; the streaming model uses 2 at most by itself. At least 1: the Mac's
    /// recognizers need one, and settings.json may say 0.
    private func threads(_ spec: ModelSpec) -> Int {
        let threads = max(services.current.threads, 1)
        return spec.engine == .parakeet ? min(threads, 4) : threads
    }

    /// The dictation key as the texts name it.
    private var keyName: String { services.current.dictationKey.displayName }

    /// A phrase as the text pipeline takes it (PLAN 3.2): cleaned, Whisper's known hallucinations on short audio and
    /// echoes of the word-list prompt dropped, then near misses of listed words fixed.
    private static func prepare(_ d: Dictation, _ raw: String?, _ samples: Int) -> String {
        let text = TranscriptText.clean(raw)
        if text.isEmpty || (!d.spec.streaming && Hallucinations.isLikely(text, samples))
            || (d.prompt != nil && Vocabulary.isEcho(text, d.words)) {
            return ""
        }

        return Vocabulary.correct(text, d.words)
    }

    /// Runs async work to the end from the speech thread, which waits for it (C#'s GetAwaiter().GetResult()). The
    /// preview's transcriptions run on the speech thread's models, one at a time, while it waits.
    private static func blocking(_ work: @escaping () async throws -> Void) throws {
        let failure = LockedValue<Error?>(nil)
        let done = DispatchSemaphore(value: 0)
        let box = Unchecked(work)
        Task.detached(priority: .userInitiated) {
            do {
                try await box.value()
            } catch {
                failure.value = error
            }

            done.signal()
        }

        done.wait()
        if let error = failure.value {
            throw error
        }
    }

    // MARK: Events, posted to the UI thread

    private func enqueue(_ work: @escaping () throws -> Void) {
        queue.async { [self] in
            if shutdown.value {
                return
            }

            do {
                try work()
            } catch {
                Log.error("action failed: \(Log.kind(of: error))")
                report(.error, "That didn't work: " + error.localizedDescription)
            }
        }
    }

    private func showPreview(_ text: String?) {
        let shown = (text ?? "").isEmpty
            ? nil : text?.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ↵ ")
        post { [self] in preview(shown) }
    }

    private func reportCaptureStopped(_ id: Int) {
        post { [self] in captureStopped(id) }
    }

    private func report(_ kind: StatusKind, _ message: String, heard: String? = nil) {
        let update = StatusUpdate(kind, message, heard: heard)
        post { [self] in status(update) }
    }

    private func postActivity(_ label: String?) {
        post { [self] in activity(label) }
    }
}

/// A value handed to another thread as it is: for closures the speech thread runs and waits for.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// One dictation, from the key to the end of typing (thumbfree-windows `DictationHost.Dictation`). Comments say which
/// thread uses what; `gate` guards what several do.
final class Dictation: @unchecked Sendable {
    let gate = NSLock()

    // Guarded by `gate`:
    /// The recording.
    var audio: [Float] = []
    /// Finished phrases, prepared, in order; they never change once added.
    var phrases: [String] = []
    /// The phrase being spoken.
    var partial = ""
    /// How much audio the streaming session has had.
    var fed = 0
    /// How much audio the preview has kept (its `committedSamples`), and whether there's a preview.
    var committed = 0
    var hasPreview = false
    var silence = AudioCapture.SilenceWatch(sampleRate: DictationHost.sampleRate)

    let stopped = LockedValue(false)
    let cancelled = LockedValue(false)
    let refused = LockedValue(false)
    let ready = LockedValue(false)
    let loadFailed = LockedValue(false)
    let typedAny = LockedValue(false)
    let limitReached = LockedValue(false)
    let feedQueued = LockedValue(false)
    let previewBusy = LockedValue(false)
    let updateQueued = LockedValue(false)
    let refusalShown = LockedValue(false)

    /// History, samples and the notification have it (or ThumbFree quitting has kept it): set by whichever got there
    /// first, so it's kept once.
    let kept = LockedValue(false)

    let startTime = ProcessInfo.processInfo.systemUptime

    /// What the end of the dictation keeps, once its text is known and before the rest of it is typed; quitting keeps
    /// it if it isn't typed in time (`DictationHost.finishForQuit`). Guarded by `gate`.
    var end: Ending?

    let id: Int
    let spec: ModelSpec

    /// Phrases are typed while speaking: Live typing is on and the model keeps up (streaming, Parakeet, or one made
    /// for it).
    let live: Bool

    /// The model that re-reads the newest audio while you speak; nil when none does.
    let previewSpec: ModelSpec?

    let smart: Bool
    let words: [String]

    /// The word list as a prompt, for the one model that's better with it (PLAN 3.2).
    let prompt: String?

    let formatter: DictationFormatter

    /// The window in front when it started; nil for the practice box or when there was none.
    let window: WindowInfo?

    /// The app of `window`, for History and samples when its box can't be read.
    let app: TargetApp?

    let practice: PracticeTarget?

    /// The text box, read when it started (nil: it couldn't tell).
    var fieldRead = Pending<DictationField?>(nil)

    /// `GuardedDesktop.typed` when the box was read: typing since then changed the text before the cursor.
    var typedAtRead = 0

    var previewTimer: DispatchSourceTimer?

    // Speech thread only:
    var session: LiveSession?
    var preview: DictationPreview?

    // Typing queue only:
    var field: DictationField?
    var info = FieldInfo(multiLine: true)
    var typing: LiveTyping?
    /// Why nothing more is typed into the box; the dictation is then kept for copying.
    var detachReason: String?
    /// The live typing was laid out for a web page's box that hadn't described itself: the box is read again right
    /// before the first piece is typed (`DictationHost.resolveBeforeTyping`).
    var provisional = false

    /// What History and samples keep of a dictation.
    struct Ending {
        var audio: [Float]
        var raw: String
        var text: String
        var info: FieldInfo
        var app: TargetApp?
    }

    init(
        id: Int, spec: ModelSpec, settings: AppSettings, formatter: DictationFormatter, window: WindowInfo?,
        app: TargetApp?, practice: PracticeTarget?, live: Bool, previewSpec: ModelSpec?
    ) {
        self.id = id
        self.spec = spec
        self.live = live
        self.previewSpec = previewSpec
        smart = settings.smartFormatting
        words = Vocabulary.parse(settings.vocabulary)
        prompt = spec.promptVocabulary ? Vocabulary.prompt(Vocabulary.parse(settings.vocabulary)) : nil
        self.formatter = formatter
        self.window = window
        self.app = app
        self.practice = practice
    }
}

extension FnTapKeys.TapKey {
    /// The key as the texts name it: "Fn" or "Right Option".
    public var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right Option"
        }
    }
}
