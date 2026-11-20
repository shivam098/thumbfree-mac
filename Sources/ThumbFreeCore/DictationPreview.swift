import Foundation

/// Live transcript while tap-to-dictate dictation is recording. Each update re-transcribes the audio after the last
/// committed point; once that exceeds the recognizer window, the oldest part is transcribed once, cut at a pause, and
/// kept, so each update costs at most a window of audio. With phrases on (live typing with a model that isn't
/// streaming), every pause also ends a phrase: its audio is transcribed once, at final quality, and never changes, so
/// it can be typed (`LiveTyping`).
public final class DictationPreview {
    private let transcribe: ([Float]) async throws -> String
    private let commit: ([Float]) async throws -> String
    private let detect: (([Float]) throws -> [SpeechRegion])?
    private let sampleRate: Int
    private let windowSamples: Int
    private let minCommitSamples: Int
    private let phrasePauseSamples: Int?
    private var committed: [String] = []

    /// - Parameters:
    ///   - transcribe: Returns cleaned text for the audio (empty when nothing was said).
    ///   - detect: Speech regions in the audio; nil treats all audio as speech. What it throws stops the update, as in
    ///     C#: a detector that failed hasn't found silence.
    ///   - phrasePauseMs: A pause at least this long ends a phrase, which is then kept; nil keeps text only past the
    ///     window.
    ///   - commit: Transcribes audio that is kept (final quality); `transcribe` when nil.
    public init(
        transcribe: @escaping ([Float]) async throws -> String,
        detect: (([Float]) throws -> [SpeechRegion])?,
        sampleRate: Int,
        windowMs: Int = 12000,
        minCommitMs: Int = 3000,
        phrasePauseMs: Int? = nil,
        commit: (([Float]) async throws -> String)? = nil
    ) {
        self.transcribe = transcribe
        self.commit = commit ?? transcribe
        self.detect = detect
        self.sampleRate = sampleRate
        windowSamples = sampleRate * windowMs / 1000
        minCommitSamples = min(sampleRate * minCommitMs / 1000, sampleRate * windowMs / 1000)
        phrasePauseSamples = phrasePauseMs.map { sampleRate * $0 / 1000 }
    }

    /// Samples from the start of the recording that are already transcribed and kept.
    public private(set) var committedSamples = 0

    /// The kept text, one entry per finished phrase (or window), in order; never changes once added.
    public var phrases: [String] { committed }

    /// The latest transcription of the audio after `committedSamples` (the phrase being spoken).
    public private(set) var tentative = ""

    /// Transcribes `pending` (the audio recorded after `committedSamples`). Throws what the detector or a transcriber
    /// throws; phrases kept before that stay kept, as in C#.
    public func update(_ pending: [Float]) async throws -> String {
        var pending = pending
        var speech = try detectSpeech(pending)
        while let pause = phrasePauseSamples, let end = Self.findPhraseEnd(speech, pending.count, sampleRate, pause) {
            let text = try await commit(Array(pending[..<end]))
            if !text.isEmpty {
                committed.append(text)
            }

            committedSamples += end
            pending = Array(pending[end...])
            speech = try detectSpeech(pending)
        }

        while pending.count > windowSamples {
            let cut = Self.findCommitPoint(speech, pending.count, sampleRate, windowSamples, minCommitSamples)
            if speech.contains(where: { DotNet.toInt32($0.start * Double(sampleRate)) < cut }) {
                let text = try await commit(Array(pending[..<cut]))
                if !text.isEmpty {
                    committed.append(text)
                }
            }

            committedSamples += cut
            pending = Array(pending[cut...])
            speech = try detectSpeech(pending)
        }

        if speech.isEmpty {
            tentative = ""
        } else {
            tentative = try await transcribe(pending)
        }

        return (committed + [tentative]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The end of the first phrase that a pause of at least `pauseSamples` has finished (speech, then that much
    /// silence, either before more speech or at the end so far): the speech's end plus up to 0.3 s. Nil if none yet.
    public static func findPhraseEnd(
        _ speech: [SpeechRegion],
        _ length: Int,
        _ sampleRate: Int,
        _ pauseSamples: Int
    ) -> Int? {
        let rate = Double(sampleRate)
        let found = speech.map {
            (start: DotNet.toInt32($0.start * rate), end: min(length, DotNet.toInt32($0.end * rate)))
        }
        let regions = DotNet.orderBy(found.filter { $0.end > $0.start }) { $0.start }
        var reach = 0
        for (i, region) in regions.enumerated() {
            reach = max(reach, region.end)
            let next = i + 1 < regions.count ? regions[i + 1].start : length
            let gap = next - reach
            if gap >= pauseSamples {
                return min(length, reach + min(gap / 2, sampleRate * 3 / 10))
            }
        }

        return nil
    }

    /// Where to cut audio longer than the window: in the latest pause between `minSamples` and `windowSamples`, else
    /// the window edge. Audio with no speech is dropped except its last second.
    public static func findCommitPoint(
        _ speech: [SpeechRegion],
        _ length: Int,
        _ sampleRate: Int,
        _ windowSamples: Int,
        _ minSamples: Int
    ) -> Int {
        if speech.isEmpty {
            return max(1, length - sampleRate)
        }

        let rate = Double(sampleRate)
        let found = speech.map { (start: DotNet.toInt32($0.start * rate), end: DotNet.toInt32($0.end * rate)) }
        let regions = DotNet.orderBy(found) { $0.start }
        var candidates = zip(regions, regions.dropFirst()).map { ($0.end + $1.start) / 2 }
        if let last = regions.last, last.end < length {
            candidates.append(min(length, last.end + sampleRate / 5))
        }

        let best = candidates.filter { $0 >= minSamples && $0 <= windowSamples }.max() ?? 0
        return best > 0 ? best : windowSamples
    }

    private func detectSpeech(_ audio: [Float]) throws -> [SpeechRegion] {
        guard let detect else { return [SpeechRegion(start: 0, end: Double(audio.count) / Double(sampleRate))] }
        return try detect(audio)
    }
}
