/// Cutting recorded audio into the pieces a recognizer gets, at the pauses a voice-activity detector found.
public enum SpeechSegments {
    /// Splits audio into chunks of at most `maxMs` for transcription, cutting only in pauses between detected speech
    /// regions where possible (long dictation exceeds Whisper's window). Returns no chunks when there is no speech.
    public static func chunk(
        _ samples: [Float],
        _ speech: [SpeechRegion],
        sampleRate: Int,
        maxMs: Int,
        padMs: Int
    ) -> [[Float]] {
        let maxSamples = sampleRate * maxMs / 1000
        let pad = sampleRate * padMs / 1000
        var chunks: [[Float]] = []
        var chunkStart: Int?
        var chunkEnd = 0
        for region in DotNet.orderBy(speech, { $0.start }) {
            let start = clamp(DotNet.toInt32(region.start * Double(sampleRate)) - pad, 0, samples.count)
            let end = clamp(DotNet.toInt32(region.end * Double(sampleRate)) + pad, start, samples.count)
            if end <= start {
                continue
            }

            if let open = chunkStart, end - open > maxSamples {
                chunks.append(Array(samples[open..<chunkEnd]))
                chunkStart = nil
            }

            var first = chunkStart ?? start
            chunkEnd = max(chunkEnd, end)

            // A single region longer than the window: cut it into window-sized pieces.
            while chunkEnd - first > maxSamples {
                chunks.append(Array(samples[first..<(first + maxSamples)]))
                first += maxSamples
            }

            chunkStart = first
        }

        if let last = chunkStart, chunkEnd > last {
            chunks.append(Array(samples[last..<chunkEnd]))
        }

        return chunks
    }

    /// Splits an utterance at pauses of at least `minGapMs` between detected speech regions, so a command that
    /// background noise glued to the previous sentence becomes its own utterance again. Returns no pieces when there is
    /// no speech.
    public static func split(
        _ samples: [Float],
        _ speech: [SpeechRegion],
        sampleRate: Int,
        minGapMs: Int,
        padMs: Int
    ) -> [[Float]] {
        let minGap = sampleRate * minGapMs / 1000
        let pad = sampleRate * padMs / 1000
        var merged: [(start: Int, end: Int)] = []
        for region in DotNet.orderBy(speech, { $0.start }) {
            let start = clamp(DotNet.toInt32(region.start * Double(sampleRate)), 0, samples.count)
            let end = clamp(DotNet.toInt32(region.end * Double(sampleRate)), start, samples.count)
            if end <= start {
                continue
            }

            if let last = merged.last, start - last.end < minGap {
                merged[merged.count - 1] = (last.start, max(last.end, end))
            } else {
                merged.append((start, end))
            }
        }

        return merged.map { Array(samples[max(0, $0.start - pad)..<min(samples.count, $0.end + pad)]) }
    }

    /// `Math.Clamp`.
    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }
}
