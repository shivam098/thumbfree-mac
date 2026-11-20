import CSherpaOnnx
import Foundation
import MachO
import ThumbFreeCore
import XCTest
@testable import ThumbFreeSpeech

/// The engines on recorded speech (tests/audio), checked the way the Android on-device tests check them. Each test runs
/// only when its model is installed (CI downloads them); timings are printed so regressions show.
final class RecognizerTests: XCTestCase {
    private static let words = ["GitHub Copilot", "Kubernetes"]

    func testSherpaRunsWithItsOwnOnnxruntimeLinkedIn() {
        print(ThumbFreeSpeech.engines)
        XCTAssertEqual(Sherpa.version, "2.0.1")
        XCTAssertEqual(Sherpa.onnxruntimeVersion, "1.28.2")
        XCTAssertEqual(WhisperRecognizer.version, "1.9.5")

        // Linked into this binary: no onnxruntime or sherpa-onnx library comes from anywhere else (Homebrew's, say).
        let images = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        XCTAssertFalse(images.isEmpty)
        let engines = images.filter { $0.lowercased().contains("onnxruntime") || $0.lowercased().contains("sherpa") }
        XCTAssertEqual(engines, [])
    }

    func testAModelSherpaRejectsThrowsInsteadOfCrashingLater() {
        var config = SherpaOnnxOfflineRecognizerConfig()

        XCTAssertThrowsError(try Sherpa.created(SherpaOnnxCreateOfflineRecognizer(&config), "test model")) { error in
            XCTAssertEqual(error.localizedDescription, "sherpa-onnx couldn't load the test model.")
        }
    }

    func testLoadsAModelFromAFolderNamedOutsideTheSystemCodePage() throws {
        let spec = try TestModels.require("en-parakeet-110m")

        // A Hindi user name puts one in every path. Windows needs 8.3 short names for it; the Mac's paths are UTF-8, as
        // sherpa-onnx's are.
        let scratch = try Scratch()
        defer { scratch.remove() }
        let folder = scratch.file("मॉडल")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for file in spec.files {
            let source = try XCTUnwrap(TestModels.store.pathOf(file))
            let copy = (folder as NSString).appendingPathComponent(file.name)
            try FileManager.default.copyItem(atPath: source, toPath: copy)
        }

        let model = try ParakeetRecognizer.load(folder, threads: 2)
        defer { model.close() }
        let logs = try Audio.read("send-logs.wav")
        XCTAssertTrue(containsIgnoringCase(try model.transcribe(logs, preview: false), "build logs"))
    }

    func testParakeetTranscribesWithPunctuationAndFixesListedWords() throws {
        let spec = try TestModels.require("en-parakeet-110m")
        let model = try timed("parakeet 110m load") {
            try Recognizers.load(spec, from: TestModels.store, threads: TestModels.threads)
        }
        defer { model.close() }
        XCTAssertTrue(model is ParakeetRecognizer)

        let sendLogs = try Audio.read("send-logs.wav")
        let logs = try XCTUnwrap(timed("parakeet 110m send-logs") { try model.transcribe(sendLogs, preview: false) })
        XCTAssertTrue(containsIgnoringCase(logs, "send me the latest build logs"), logs)
        XCTAssertTrue(logs.trimmingCharacters(in: .whitespaces).hasSuffix("."), logs)

        let genres = try XCTUnwrap(try model.transcribe(Audio.read("genres.wav"), preview: false))
        XCTAssertTrue(containsIgnoringCase(genres, "videos of different genres"), genres)

        let dictation = try Audio.read("dictation.wav")
        let raw = try XCTUnwrap(timed("parakeet 110m dictation") { try model.transcribe(dictation, preview: false) })
        let text = format(raw)
        print("formatted: \(text)")
        XCTAssertTrue(text.contains("GitHub Copilot"), text)
        XCTAssertTrue(text.contains("pull request,"), text)
        XCTAssertFalse(containsIgnoringCase(text, " um "), text)

        // Clips under a second are padded, not refused.
        XCTAssertNotNil(try model.transcribe(Audio.silence(ms: 100), preview: true))

        model.abort()
        XCTAssertNil(try model.transcribe(sendLogs, preview: false))
        model.resume()
        XCTAssertTrue(containsIgnoringCase(try model.transcribe(sendLogs, preview: true), "build"))

        // 31 s of speech takes a few hundred ms: aborted while it runs, the result is thrown away.
        try abortDuringACall(model, dictation + dictation + dictation)
        XCTAssertTrue(containsIgnoringCase(try model.transcribe(sendLogs, preview: false), "build"))

        model.close()
        XCTAssertNil(try model.transcribe(sendLogs, preview: false))
    }

    func testParakeetAccurateTranscribesADictation() throws {
        let spec = try TestModels.require("en-parakeet-0.6b")
        let model = try timed("parakeet 0.6b load") {
            try Recognizers.load(spec, from: TestModels.store, threads: TestModels.threads)
        }
        defer { model.close() }

        let sendLogs = try Audio.read("send-logs.wav")
        let logs = try XCTUnwrap(timed("parakeet 0.6b send-logs") { try model.transcribe(sendLogs, preview: false) })
        XCTAssertTrue(containsIgnoringCase(logs, "send me the latest build logs"), logs)
        XCTAssertTrue(logs.trimmingCharacters(in: .whitespaces).hasSuffix("."), logs)

        let dictation = try Audio.read("dictation.wav")
        let raw = try XCTUnwrap(timed("parakeet 0.6b dictation") { try model.transcribe(dictation, preview: false) })
        let text = format(raw)
        XCTAssertTrue(text.contains("GitHub Copilot"), text)
        XCTAssertTrue(containsIgnoringCase(text, "pull request"), text)
    }

    func testKrokoTypesWhileYouSpeakAndFinishesWithPunctuation() throws {
        let spec = try TestModels.require("en-kroko-live")
        let model = try timed("kroko load") {
            try StreamingRecognizer.load(TestModels.store.directoryOf(spec), threads: TestModels.threads)
        }
        defer { model.close() }
        XCTAssertTrue(model.punctuates)

        // As the app does: 100 ms of audio at a time, text back after each.
        let audio = try Audio.read("dictation.wav")
        var seen: [String] = []
        let started = Date()
        let phrases: [String]
        do {
            let session = try model.startSession()
            defer { session.close() }
            for chunk in Audio.chunks(audio) {
                seen.append(session.accept(chunk))
            }

            phrases = session.finish()
            XCTAssertEqual(session.finish(), phrases)
            XCTAssertEqual(session.finishText(), LiveText.endSentence(LiveText.join(phrases, "")))
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let text = LiveText.endSentence(LiveText.join(phrases, ""))
        print("kroko live: \(ms) ms for \(audio.count / 16) ms of audio, phrases: \(phrases.joined(separator: " | "))")
        XCTAssertLessThan(ms, audio.count / 16, "keeps up with speech")
        let early = seen.prefix(seen.count / 2)
        XCTAssertTrue(early.contains { !$0.isEmpty }, "text arrives while speaking: \(seen.prefix(40))")
        XCTAssertTrue(phrases.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "\(phrases)")
        let fixedText = Vocabulary.correct(text, Self.words)
        XCTAssertTrue(fixedText.contains("GitHub Copilot"), fixedText)
        XCTAssertTrue(containsIgnoringCase(fixedText, "pull request"), fixedText)
        XCTAssertTrue(text.contains { $0 == "." || $0 == "," || $0 == "?" }, "punctuated: \(text)")
        XCTAssertFalse(matchesPattern(text, "[.,?!;:]{2}"), text)

        let sendLogs = try Audio.read("send-logs.wav")
        let logs = try XCTUnwrap(timed("kroko whole recording") { try model.transcribe(sendLogs, preview: false) })
        XCTAssertTrue(logs.hasSuffix("."), logs)
        XCTAssertTrue(containsIgnoringCase(logs, "send me the latest build logs"), logs)

        model.abort()
        XCTAssertNil(try model.transcribe(audio, preview: false))
        model.resume()
        XCTAssertEqual(try model.transcribe(Audio.silence(ms: 1000), preview: false), "")

        // Aborted while it runs, the transcription stops at the next 100 ms.
        try abortDuringACall(model, audio + audio + audio)
    }

    func testKrokoKeepsTheLastWordsWhenYouFinishRightAfterSpeaking() throws {
        let spec = try TestModels.require("en-kroko-live")
        let model = try StreamingRecognizer.load(TestModels.store.directoryOf(spec), threads: TestModels.threads)
        defer { model.close() }
        let clips = [
            ("send-logs.wav", "latest build logs"),
            ("genres.wav", "different genres"),
            ("dictation.wav", "push the build"),
        ]
        for (clip, lastWords) in clips {
            // The clips end with about 0.75 s of silence: cutting 0.7 s is a tap to finish right after the last word.
            // Silence in front moves that end to other places in Kroko's 1.28 s windows, where different amounts of
            // tail are needed.
            let full = try Audio.read(clip)
            let speech = Array(full.dropLast(Decoding.sampleRate * 7 / 10))
            for lead in [0, 400, 800] {
                let audio = Audio.silence(ms: lead) + speech
                let session = try model.startSession()
                for chunk in Audio.chunks(audio) {
                    session.accept(chunk)
                }

                let live = session.finishText()
                session.close()
                let whole = try model.transcribe(audio, preview: false)
                print("\(clip) after \(lead) ms: \(live)")
                XCTAssertTrue(containsIgnoringCase(live, lastWords), "\(clip) after \(lead) ms, session: \(live)")
                XCTAssertTrue(
                    containsIgnoringCase(whole, lastWords), "\(clip) after \(lead) ms, transcribe: \(whole ?? "nil")")
            }
        }
    }

    func testKrokoKeepsItsOwnMarksWithoutDoublingThem() throws {
        let spec = try TestModels.require("en-kroko-live")
        let model = try StreamingRecognizer.load(TestModels.store.directoryOf(spec), threads: TestModels.threads)
        defer { model.close() }

        // Phrases as Kroko writes them (its vocabulary has . , ? ! : ; and ...). The punctuation model hardly ever ends
        // a phrase with a mark itself; given Kroko's marks, it repeats them, sometimes twice ("build..", "logs.,"), and
        // adds stray commas ("build, logs.").
        let question = model.punctuate("is it ready?")
        let dictation = model.punctuate(
            "so um I wanted to check the pull request comma and then I'm merge it into main full stop new line after "
                + "that we can ask GitHub copilot to review the Kubernet's config and push the build.")
        let logs = model.punctuate("Please send me the latest build logs.")
        print("\(question) | \(dictation) | \(logs)")
        XCTAssertEqual(question, "Is it ready?")
        XCTAssertTrue(dictation.hasSuffix("push the build."), dictation)
        XCTAssertTrue(logs.contains("send me the latest build logs."), logs)

        // On speech: the three clips back to back, where Kroko writes "logs." and "genres." in the middle of a phrase.
        let audio = try Audio.read("send-logs.wav") + Audio.read("genres.wav") + Audio.read("dictation.wav")
        let session = try model.startSession()
        defer { session.close() }
        for chunk in Audio.chunks(audio) {
            session.accept(chunk)
        }

        let phrases = session.finish()
        print(phrases.joined(separator: " | "))
        for text in phrases + [question, dictation, logs] {
            XCTAssertFalse(matchesPattern(text, "[.,?!;:]{2}"), text)
        }
    }

    func testEachWordKeepsItsFirstMark() {
        let cases = [
            ("push the Build..", "push the Build."),
            ("I saw it yesterday., then", "I saw it yesterday. then"),
            ("Is it Ready?.", "Is it Ready?"),
            ("wait... what?!", "wait. what?"),
            ("e.g. the U.S., then", "e.g. the U.S. then"),
            ("Hi, all. Done?", "Hi, all. Done?"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(StreamingRecognizer.firstMarks(text), expected, text)
        }
    }

    /// Runs before the Whisper and Silero tests (the tests run in name order), so it pays for ggml's setup.
    func testEnginesWarmUpOnceInTheBackgroundAndADetectorWorksAfterwards() async throws {
        // Callers on many threads: one warm-up, and each callback once (more than once fails the test).
        let first = expectation(description: "the first callback")
        let second = expectation(description: "the second callback")
        ThumbFreeSpeech.warmUp { first.fulfill() }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in ThumbFreeSpeech.warmUp() }
        ThumbFreeSpeech.warmUp { second.fulfill() }
        let started = Date()
        await ThumbFreeSpeech.waitForWarmUp()
        print("ggml warm-up: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        await fulfillment(of: [first, second], timeout: 10)
        XCTAssertTrue(ThumbFreeSpeech.isWarmedUp)
        XCTAssertEqual(Ggml.runs, 1)

        // Once it's done, a callback comes straight away and nothing runs again.
        let late = expectation(description: "a callback after the warm-up")
        ThumbFreeSpeech.warmUp { late.fulfill() }
        await fulfillment(of: [late], timeout: 10)

        let path = try TestModels.require(ModelCatalog.vad)
        let detector = try timed("silero load after the warm-up") { try SpeechDetector(modelPath: path) }
        defer { detector.close() }
        XCTAssertFalse(try detector.detect(Audio.read("send-logs.wav")).isEmpty)
        XCTAssertEqual(Ggml.runs, 1)
    }

    func testKrokoFinishesAPhraseAtEachPauseWhileYouSpeak() throws {
        let spec = try TestModels.require("en-kroko-live")
        let model = try StreamingRecognizer.load(TestModels.store.directoryOf(spec), threads: TestModels.threads)
        defer { model.close() }
        let audio = try Audio.read("send-logs.wav") + Audio.silence(ms: 1500) + Audio.read("genres.wav")
        let session = try model.startSession()
        defer { session.close() }
        var partialSeen = false
        for chunk in Audio.chunks(audio) {
            session.accept(chunk)
            partialSeen = partialSeen || !session.partial.isEmpty
        }

        let whileSpeaking = session.finished
        let phrases = session.finish()

        print("phrases: \(phrases.joined(separator: " | "))")
        XCTAssertTrue(partialSeen)
        XCTAssertFalse(whileSpeaking.isEmpty)
        XCTAssertTrue(containsIgnoringCase(whileSpeaking.first, "send me the latest build logs"), "\(whileSpeaking)")
        XCTAssertTrue(matchesPattern(whileSpeaking.first ?? "", "^[A-Z]"), "\(whileSpeaking)")
        XCTAssertEqual(Array(phrases.prefix(whileSpeaking.count)), whileSpeaking)
        XCTAssertGreaterThan(phrases.count, whileSpeaking.count, "the last phrase comes from finish")
        XCTAssertTrue(containsIgnoringCase(phrases.dropFirst().joined(separator: " "), "videos of different genres"))
    }

    func testClosingTheStreamingModelEndsItsSessions() throws {
        let spec = try TestModels.require("en-kroko-live")
        let model = try StreamingRecognizer.load(TestModels.store.directoryOf(spec), threads: TestModels.threads)
        let session = try model.startSession()
        let sendLogs = try Audio.read("send-logs.wav")
        session.accept(sendLogs)

        model.close()
        model.close()

        XCTAssertEqual(session.accept(Audio.silence(ms: 1000)), session.text)
        XCTAssertEqual(session.finish(), session.finished)
        session.close()
        XCTAssertThrowsError(try model.startSession()) { XCTAssertEqual($0 as? SpeechError, .closed) }
        XCTAssertNil(try model.transcribe(sendLogs, preview: false))
    }

    func testWhisperWorksThroughTheSameInterface() throws {
        let spec = try TestModels.require("hinglish-swift")
        let model = try timed("whisper hinglish load") {
            try Recognizers.load(spec, from: TestModels.store, threads: TestModels.threads)
        }
        defer { model.close() }
        XCTAssertTrue(model is WhisperRecognizer)

        let sendLogs = try Audio.read("send-logs.wav")
        let logs = try timed("whisper hinglish send-logs") { try model.transcribe(sendLogs, preview: false) }
        XCTAssertTrue(containsIgnoringCase(logs, "build logs"), logs ?? "nil")

        let genresAudio = try Audio.read("genres.wav")
        let genres = try timed("whisper hinglish with a prompt") {
            try model.transcribe(genresAudio, preview: false, prompt: "GitHub Copilot, genres")
        }
        XCTAssertTrue(containsIgnoringCase(genres, "genres"), genres ?? "nil")

        model.abort()
        XCTAssertNil(try model.transcribe(sendLogs, preview: false))
        model.resume()
        XCTAssertTrue(containsIgnoringCase(try model.transcribe(sendLogs, preview: true), "logs"))

        // whisper.cpp isn't stopped midway (nor is it through Whisper.net on Windows): the result is thrown away.
        try abortDuringACall(model, Audio.read("dictation.wav"))
        XCTAssertTrue(containsIgnoringCase(try model.transcribe(sendLogs, preview: false), "logs"))
    }

    func testWhisperGivesTheTextWithItsProbability() throws {
        let spec = try TestModels.require("hinglish-swift")
        let path = try XCTUnwrap(TestModels.store.pathOf(spec.files[0]))
        let model = try WhisperRecognizer(modelPath: path, options: RecognizerOptions(threads: TestModels.threads))
        defer { model.close() }

        let result = try model.transcribeResult(Audio.read("send-logs.wav"))

        print("whisper hinglish: \(Int(result.elapsed * 1000)) ms, p = \(result.probability): \(result.text)")
        XCTAssertTrue(containsIgnoringCase(result.text, "build logs"), result.text)
        XCTAssertTrue((0.3...1).contains(result.probability), "\(result.probability)")
        model.close()
        XCTAssertThrowsError(try model.transcribeResult(Audio.silence(ms: 1000))) {
            XCTAssertEqual($0 as? SpeechError, .closed)
        }
    }

    func testSileroFindsTheSpeechAndThePauseBetweenTwoClips() throws {
        let path = try TestModels.require(ModelCatalog.vad)
        let detector = try timed("silero load") { try SpeechDetector(modelPath: path) }
        defer { detector.close() }

        let logs = try Audio.read("send-logs.wav")
        let seconds = Double(logs.count) / Double(Decoding.sampleRate)
        let regions = try timed("silero send-logs") { try detector.detect(logs) }
        print("send-logs: \(regions)")
        XCTAssertFalse(regions.isEmpty)
        XCTAssertEqual(regions, regions.sorted { $0.start < $1.start })
        let inside = regions.allSatisfy { $0.start >= 0 && $0.start < $0.end && $0.end <= seconds + 0.05 }
        XCTAssertTrue(inside, "\(regions)")

        // 1.5 s of silence between two clips is a pause: speech on both sides of it, none in it.
        let both = try detector.detect(logs + Audio.silence(ms: 1500) + Audio.read("genres.wav"))
        print("with a pause: \(both)")
        XCTAssertTrue(both.contains { $0.end <= seconds + 0.25 }, "\(both)")
        XCTAssertTrue(both.contains { $0.start >= seconds + 1.25 }, "\(both)")
        XCTAssertFalse(both.contains { $0.start < seconds + 1.25 && $0.end > seconds + 0.25 }, "\(both)")

        XCTAssertEqual(try detector.detect(Audio.silence(ms: 2000)), [])
        detector.close()
        XCTAssertThrowsError(try detector.detect(logs)) { XCTAssertEqual($0 as? SpeechError, .closed) }
    }

    /// The app gives the detector to the core's DictationPreview as it is: a pause it finds ends a phrase.
    func testTheDetectorGoesStraightIntoDictationPreview() async throws {
        let path = try TestModels.require(ModelCatalog.vad)
        let detector = try SpeechDetector(modelPath: path)
        defer { detector.close() }

        // Each transcription is the length of the audio it got, in seconds.
        let rate = Decoding.sampleRate
        let preview = DictationPreview(
            transcribe: { String(format: "%.2f", Double($0.count) / Double(rate)) },
            detect: detector.detect,
            sampleRate: rate,
            phrasePauseMs: 1200)
        let logs = try Audio.read("send-logs.wav")
        let audio = try logs + Audio.silence(ms: 1500) + Audio.read("genres.wav")
        let text = try await preview.update(audio)
        print("preview: \(preview.phrases) + \(preview.tentative)")

        // The phrase ends in the pause: after the speech the detector finds in send-logs.wav, before genres.wav.
        let speechEnd = try XCTUnwrap(try detector.detect(logs).last).end
        let end = Double(preview.committedSamples) / Double(rate)
        XCTAssertGreaterThan(end, speechEnd)
        XCTAssertLessThan(end, Double(logs.count) / Double(rate) + 1.5)
        XCTAssertEqual(preview.phrases, [String(format: "%.2f", end)])
        let rest = Double(audio.count - preview.committedSamples) / Double(rate)
        XCTAssertEqual(preview.tentative, String(format: "%.2f", rest))
        XCTAssertEqual(text, (preview.phrases + [preview.tentative]).joined(separator: " "))

        // What the detector throws stops the update.
        detector.close()
        do {
            _ = try await preview.update(Audio.silence(ms: 1000))
            XCTFail("a closed detector stops the update")
        } catch {
            XCTAssertEqual(error as? SpeechError, .closed)
        }
    }

    func testReadsTheRecordingsAsSamplesAndRefusesOtherFormats() throws {
        let samples = try Audio.read("send-logs.wav")
        XCTAssertEqual(Double(samples.count) / Double(Decoding.sampleRate), 2.9, accuracy: 0.1)
        XCTAssertTrue(samples.allSatisfy { $0 >= -1 && $0 < 1 })
        XCTAssertTrue(samples.contains { abs($0) > 0.05 })

        let scratch = try Scratch()
        defer { scratch.remove() }
        let notWav = scratch.file("not.wav")
        try Data("hello".utf8).write(to: URL(fileURLWithPath: notWav))
        XCTAssertThrowsError(try WavFile.readPcm16Mono16k(notWav)) {
            XCTAssertEqual($0 as? SpeechError, .invalidData("Not a RIFF file."))
        }

        let phone = scratch.file("8k.wav")
        try wav(rate: 8000, samples: [0, 1000, -1000]).write(to: URL(fileURLWithPath: phone))
        XCTAssertThrowsError(try WavFile.readPcm16Mono16k(phone)) {
            XCTAssertEqual($0 as? SpeechError, .invalidData("Expected 16 kHz mono 16-bit, got 8000 Hz 1 ch 16-bit."))
        }

        let tiny = scratch.file("16k.wav")
        try wav(rate: 16000, samples: [0, 16384, -32768]).write(to: URL(fileURLWithPath: tiny))
        XCTAssertEqual(try WavFile.readPcm16Mono16k(tiny), [0, 0.5, -1])
    }

    /// The text as the app types it (C#'s Format): cleaned, the listed words written as listed, then formatted.
    private func format(_ raw: String) -> String {
        DictationFormatter().format(Vocabulary.correct(TranscriptText.clean(raw), Self.words))
    }

    /// Starts a transcription on another thread and aborts it 50 ms in (it takes several times that): the call returns
    /// nil, and the recognizer works again after `resume`.
    private func abortDuringACall(_ model: Recognizer, _ audio: [Float]) throws {
        let result = Locked<Result<String?, Error>?>(nil)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let call = Thread {
            started.signal()
            result.value = Result { try model.transcribe(audio, preview: false) }
            finished.signal()
        }

        call.start()
        started.wait()
        Thread.sleep(forTimeInterval: 0.05)
        model.abort()
        finished.wait()
        model.resume()
        XCTAssertNil(try XCTUnwrap(result.value).get())
    }

    /// A mono 16-bit PCM WAV file.
    private func wav(rate: UInt32, samples: [Int16]) -> Data {
        var data = Data()
        func add<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        add(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        add(UInt32(16))
        add(UInt16(1))
        add(UInt16(1))
        add(rate)
        add(rate * 2)
        add(UInt16(2))
        add(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        add(UInt32(samples.count * 2))
        for sample in samples {
            add(sample)
        }

        return data
    }
}
