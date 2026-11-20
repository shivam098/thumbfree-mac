import CSherpaOnnx
import Foundation
import ThumbFreeCore

/// A streaming model (Kroko Zipformer) through sherpa-onnx's online recognizer, for live typing (the Android app's
/// StreamingRecognizer): audio goes in as it's recorded and the text so far comes straight back. A phrase ends at a
/// short pause; each finished phrase gets punctuation from a small model, keeping the recognizer's words and capitals.
public final class StreamingRecognizer: Recognizer, @unchecked Sendable {
    /// 100 ms: how much audio `transcribe` feeds at a time, as the app does while recording.
    public static let chunkSamples = Decoding.sampleRate / 10

    /// Silence `Session.finish` adds after the last words: at least 1 s, at most 3 s (see there).
    private static let minTailSamples = Decoding.sampleRate

    private static let maxTailSamples = Decoding.sampleRate * 3

    /// The marks `LiveText.mergePunctuation` takes from the punctuation model.
    private static let marks: Set<Unicode.Scalar> = [".", ",", "?", "!", ";", ":"]

    private static let markRun = try! NSRegularExpression(pattern: "([.,?!;:])[.,?!;:]+(?=\\s|$)")

    fileprivate let recognizer: OpaquePointer
    private let punctuation: OpaquePointer?

    /// Held while a session decodes and while the models are freed (re-entrant, like C#'s `lock`).
    fileprivate let gate = NSRecursiveLock()

    /// The open sessions, weakly: a session keeps its model alive, not the other way round.
    fileprivate var sessions: [ObjectIdentifier: WeakSession] = [:]

    private let aborted = Flag()
    fileprivate var closed = false

    private init(_ recognizer: OpaquePointer, _ punctuation: OpaquePointer?) {
        self.recognizer = recognizer
        self.punctuation = punctuation
    }

    deinit {
        close()
    }

    /// Whether finished phrases get punctuation (the punctuation model is present and loaded).
    public var punctuates: Bool { punctuation != nil }

    /// Loads the Kroko streaming model (and the punctuation model when present) from `directory`.
    public static func load(_ directory: String, threads: Int) throws -> StreamingRecognizer {
        precondition(threads >= 1, "threads must be at least 1")
        let paths = try Sherpa.requireFiles(directory, ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"])
        let recognizer = try CStrings.with { text -> OpaquePointer in
            var config = SherpaOnnxOnlineRecognizerConfig()
            config.feat_config.sample_rate = Int32(Decoding.sampleRate)
            config.feat_config.feature_dim = 80
            config.model_config.transducer.encoder = text(paths[0])
            config.model_config.transducer.decoder = text(paths[1])
            config.model_config.transducer.joiner = text(paths[2])
            config.model_config.tokens = text(paths[3])

            // Two threads already run ~10x faster than you speak.
            config.model_config.num_threads = Int32(min(threads, 2))
            config.model_config.provider = text("cpu")

            // A phrase ends after 0.8 s of silence (punctuation is added then). As on Android: rule 1 (2.4 s of silence
            // before any word) and rule 3 (a 20 s phrase) also end it; sherpa-onnx requires a word only for rule 2.
            config.enable_endpoint = 1
            config.rule1_min_trailing_silence = 2.4
            config.rule2_min_trailing_silence = 0.8
            config.rule3_min_utterance_length = 20
            config.decoding_method = text("greedy_search")
            return try Sherpa.created(SherpaOnnxCreateOnlineRecognizer(&config), "streaming model")
        }

        return StreamingRecognizer(recognizer, loadPunctuation(directory))
    }

    /// Speech thread: a new dictation. Close it (or call `Session.finish`) when done. Throws `SpeechError.closed` once
    /// the model is closed.
    public func startSession() throws -> Session {
        gate.lock()
        defer { gate.unlock() }
        guard !closed, let stream = SherpaOnnxCreateOnlineStream(recognizer) else { throw SpeechError.closed }
        let session = Session(self, stream)
        sessions[ObjectIdentifier(session)] = WeakSession(session: session)
        return session
    }

    /// The whole recording at once, fed 100 ms at a time (tests, and the fallback when no live session ran). `preview`
    /// and `prompt` are ignored: a streaming model gives the same text either way.
    public func transcribe(_ samples16k: [Float], preview: Bool, prompt: String?) -> String? {
        if aborted.isSet {
            return nil
        }

        guard let session = try? startSession() else { return nil }
        defer { session.close() }
        for start in stride(from: 0, to: samples16k.count, by: Self.chunkSamples) {
            session.accept(Array(samples16k[start..<min(samples16k.count, start + Self.chunkSamples)]))
            if aborted.isSet {
                return nil
            }
        }

        return session.finishText()
    }

    public func abort() { aborted.set(true) }

    public func resume() { aborted.set(false) }

    /// Ends open sessions and frees the models. Safe to call twice.
    public func close() {
        aborted.set(true)
        gate.lock()
        defer { gate.unlock() }
        if closed {
            return
        }

        closed = true
        for entry in Array(sessions.values) {
            entry.session?.closeLocked()
        }

        SherpaOnnxDestroyOnlineRecognizer(recognizer)
        if let punctuation {
            SherpaOnnxDestroyOnlinePunctuation(punctuation)
        }
    }

    private static func loadPunctuation(_ directory: String) -> OpaquePointer? {
        let model = Files.combine(directory, "punct.int8.onnx")
        let vocab = Files.combine(directory, "punct-bpe.vocab")
        guard Files.isFile(model), Files.isFile(vocab) else { return nil }
        return CStrings.with { text -> OpaquePointer? in
            var config = SherpaOnnxOnlinePunctuationConfig()
            config.model.cnn_bilstm = text(Sherpa.nativePath(model))
            config.model.bpe_vocab = text(Sherpa.nativePath(vocab))
            config.model.num_threads = 1
            config.model.provider = text("cpu")

            // Phrases are typed without punctuation rather than not at all.
            return try? Sherpa.created(SherpaOnnxCreateOnlinePunctuation(&config), "punctuation model")
        }
    }

    /// Punctuation from the small model, merged into the recognizer's words and capitals (`LiveText.mergePunctuation`).
    /// Kroko writes a few marks itself ("is it ready?", "push the build."). The model gets the bare words: given
    /// Kroko's marks it repeats them, sometimes twice ("build..", "logs.,"), and adds stray commas ("build, logs.").
    /// Kroko's marks are then put back where it wrote them, since the model hardly ever ends a phrase with one (a
    /// question would lose its "?"), and each word keeps one mark. Best effort: the phrase is kept as recognized if
    /// anything goes wrong.
    func punctuate(_ text: String) -> String {
        gate.lock()
        defer { gate.unlock() }
        guard let punctuation, !closed else { return text }
        let words = Self.splitOnSpaces(text)
        let bare = words.map(Self.withoutMarks)
        guard bare.allSatisfy({ !$0.isEmpty }) else { return text }
        let added: UnsafePointer<CChar>? = bare.joined(separator: " ").withCString {
            SherpaOnnxOnlinePunctuationAddPunct(punctuation, $0)
        }
        guard let added else { return text }
        let model = Self.splitOnSpaces(String(cString: added))
        SherpaOnnxOnlinePunctuationFreeText(added)
        if model.count != words.count {
            return text
        }

        let marked = model.indices.map { i -> String in
            let own = words[i].unicodeScalars
            let bareLength = bare[i].unicodeScalars.count
            guard own.count > bareLength else { return model[i] }
            var word = Self.withoutMarks(model[i])
            word.unicodeScalars.append(own[own.index(own.startIndex, offsetBy: bareLength)])
            return word
        }

        return LiveText.mergePunctuation(text, Self.firstMarks(marked.joined(separator: " ")))
    }

    /// Reduces each run of marks at the end of a word to its first mark: "build.." → "build.", "Ready?." → "Ready?".
    static func firstMarks(_ text: String) -> String {
        markRun.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    /// `text.Split(' ', StringSplitOptions.RemoveEmptyEntries)`: the runs between spaces (U+0020 only).
    private static func splitOnSpaces(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: " ").map { String(Substring($0)) }
    }

    /// `word.TrimEnd(Marks)`.
    private static func withoutMarks(_ word: String) -> String {
        var scalars = word.unicodeScalars[...]
        while let last = scalars.last, marks.contains(last) {
            scalars = scalars.dropLast()
        }

        return String(Substring(scalars))
    }

    fileprivate struct WeakSession {
        weak var session: Session?
    }

    /// One dictation. `accept` and `finish` run on the speech thread; the text properties can be read from any thread.
    public final class Session: @unchecked Sendable {
        private let owner: StreamingRecognizer
        private let stream: OpaquePointer
        private var finishedPhrases: [String] = []
        private var partialText = ""
        private var done = false

        fileprivate init(_ owner: StreamingRecognizer, _ stream: OpaquePointer) {
            self.owner = owner
            self.stream = stream
        }

        deinit {
            close()
        }

        /// Phrases that ended at a pause, punctuated, in order (a copy). The app types each one as it arrives.
        public var finished: [String] {
            owner.gate.lock()
            defer { owner.gate.unlock() }
            return finishedPhrases
        }

        /// The words of the phrase still being spoken (no punctuation yet): shown in the pill, not typed.
        public var partial: String {
            owner.gate.lock()
            defer { owner.gate.unlock() }
            return partialText
        }

        /// The text so far: finished phrases, then the phrase in progress.
        public var text: String {
            owner.gate.lock()
            defer { owner.gate.unlock() }
            return LiveText.join(finishedPhrases, partialText)
        }

        /// Adds 16 kHz audio (the app sends 100 ms at a time) and returns the text so far.
        @discardableResult
        public func accept(_ chunk: [Float]) -> String {
            owner.gate.lock()
            defer { owner.gate.unlock() }
            if owner.closed || done {
                return LiveText.join(finishedPhrases, partialText)
            }

            acceptLocked(chunk)
            partialText = resultLocked()
            if SherpaOnnxOnlineStreamIsEndpoint(owner.recognizer, stream) != 0 {
                if !partialText.isEmpty {
                    finishedPhrases.append(owner.punctuate(partialText))
                }

                partialText = ""
                SherpaOnnxOnlineStreamReset(owner.recognizer, stream)
            }

            return LiveText.join(finishedPhrases, partialText)
        }

        /// Flushes the last words and returns every phrase of the dictation, punctuated and in order: the app types the
        /// ones it hasn't typed yet. The session can't be used afterwards; calling it again returns the same phrases.
        ///
        /// sherpa-onnx only decodes whole windows (Kroko: 1.41 s of audio, moving on 1.28 s at a time), so the last
        /// words of a dictation finished right after speaking wait for audio after them. Silence goes in 100 ms at a
        /// time until two windows past the end are decoded, which covers every recorded frame, and at least 1 s of it,
        /// for models with shorter windows. For Kroko that's 1.3–2.7 s of silence and two decodes (about 0.1 s); a
        /// fixed 1 s lost the last words at a third of the alignments tested.
        @discardableResult
        public func finish() -> [String] {
            owner.gate.lock()
            defer { owner.gate.unlock() }
            if !owner.closed && !done {
                let silence = [Float](repeating: 0, count: StreamingRecognizer.chunkSamples)
                let minTail = StreamingRecognizer.minTailSamples
                let maxTail = StreamingRecognizer.maxTailSamples
                var decodes = 0
                var tail = 0
                while (decodes < 2 || tail < minTail) && tail < maxTail {
                    decodes += acceptLocked(silence)
                    tail += silence.count
                }

                SherpaOnnxOnlineStreamInputFinished(stream)
                decodeLocked()
                let last = resultLocked()
                if !last.isEmpty {
                    finishedPhrases.append(owner.punctuate(last))
                }

                partialText = ""
            }

            closeLocked()
            return finishedPhrases
        }

        /// `finish` as one text that ends like a sentence (the Android app's finish()): the last phrase, cut at a
        /// pause, may end in a comma, which becomes a full stop.
        public func finishText() -> String {
            LiveText.endSentence(LiveText.join(finish(), ""))
        }

        /// Stops without flushing (cancel). Safe to call twice.
        public func close() {
            owner.gate.lock()
            defer { owner.gate.unlock() }
            closeLocked()
        }

        fileprivate func closeLocked() {
            if done {
                return
            }

            done = true
            SherpaOnnxDestroyOnlineStream(stream)
            owner.sessions[ObjectIdentifier(self)] = nil
        }

        /// Feeds `samples` and decodes every window that's ready; returns how many were.
        @discardableResult
        private func acceptLocked(_ samples: [Float]) -> Int {
            if !samples.isEmpty {
                samples.withUnsafeBufferPointer {
                    let count = Int32($0.count)
                    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(Decoding.sampleRate), $0.baseAddress, count)
                }
            }

            return decodeLocked()
        }

        @discardableResult
        private func decodeLocked() -> Int {
            var decodes = 0
            while SherpaOnnxIsOnlineStreamReady(owner.recognizer, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(owner.recognizer, stream)
                decodes += 1
            }

            return decodes
        }

        /// The text of the phrase in progress, trimmed.
        private func resultLocked() -> String {
            guard let result = SherpaOnnxGetOnlineStreamResult(owner.recognizer, stream) else { return "" }
            defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
            return Sherpa.string(result.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
