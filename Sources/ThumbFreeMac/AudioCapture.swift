import AVFoundation
import Foundation

/// The microphone as 16 kHz mono Float32 samples, the format every speech model takes, in chunks of 30 ms (480
/// samples, the Windows app's microphone buffers), each with its level for the pill's meter. Audio stays in memory and
/// is never written to disk.
///
/// AVAudioEngine's input is converted with AVAudioConverter. When the input device or its format changes
/// (`AVAudioEngineConfigurationChange`), the capture starts again on the new one by itself. The conversion
/// (Converter), the chunks (Chunker), the level (`level(of:)`) and the silent-microphone check (SilenceWatch) are
/// separate so they can be tested with made-up buffers; the microphone itself is behind Input.
///
/// Without the Microphone permission (Permissions), macOS sends silence, which SilenceWatch reports.
@MainActor
public final class AudioCapture {
    nonisolated public static let sampleRate = 16_000
    nonisolated public static let chunkSamples = 480

    /// Runs on the capture thread with each chunk, in order. One more chunk may come just after `stop()`.
    public var onChunk: (@Sendable (Chunk) -> Void)? {
        get { pipeline.onChunk }
        set { pipeline.onChunk = newValue }
    }

    /// Runs on the main thread when the microphone stopped by itself and couldn't start again (it was unplugged and
    /// there's no other one); `isRunning` is false by then.
    public var onFailure: ((Error) -> Void)?

    public private(set) var isRunning = false

    private let input: any Input
    private let pipeline: Pipeline

    /// - Parameters:
    ///   - input: Where the audio comes from; the Mac's current input device when nil.
    ///   - chunkSamples: The samples in each chunk.
    public init(input: (any Input)? = nil, chunkSamples: Int = AudioCapture.chunkSamples) {
        self.input = input ?? EngineInput()
        pipeline = Pipeline(chunkSamples: chunkSamples)
    }

    /// Starts the microphone. Throws when it can't (no input device, or the engine didn't start).
    public func start() throws {
        guard !isRunning else { return }
        pipeline.begin()
        try startInput()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        input.stop()
        pipeline.end()
    }

    private func startInput() throws {
        let pipeline = self.pipeline
        let generation = pipeline.generation
        do {
            try input.start(
                buffers: { buffer in pipeline.add(buffer, generation: generation) },
                changed: { [weak self] in self?.configurationChanged(generation) })
        } catch {
            pipeline.end()
            throw error
        }
    }

    /// The device or its format changed and the input stopped itself: start it again, on the new format.
    private func configurationChanged(_ generation: Int) {
        guard isRunning, generation == pipeline.generation else { return }
        input.stop()
        pipeline.restart()
        do {
            try startInput()
        } catch {
            isRunning = false
            onFailure?(error)
        }
    }

    /// Loudness for the level meter: 0 for silence (at or below -60 dBFS) up to 1 for loud speech (-12 dBFS and
    /// above), from the RMS. The port of the C# core's `AudioLevel.Of`.
    nonisolated public static func level<Samples: Collection>(of samples: Samples) -> Float
    where Samples.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            sum += Double(sample * sample)
        }

        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let floorDb = -60.0
        let ceilingDb = -12.0
        let db = 20 * log10(rms)
        return Float(min(max((db - floorDb) / (ceilingDb - floorDb), 0), 1))
    }
}

extension AudioCapture {
    /// 30 ms of microphone audio.
    public struct Chunk: Equatable, Sendable {
        /// 16 kHz mono samples, from -1 to 1.
        public var samples: [Float]
        /// The level meter's value for these samples, from 0 to 1.
        public var level: Float

        public init(samples: [Float]) {
            self.samples = samples
            level = AudioCapture.level(of: samples)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The Mac has no input device, or it reports no channels.
        case noMicrophone
    }

    /// Where the audio comes from: AVAudioEngine's input (EngineInput), or a fake in tests.
    public protocol Input: AnyObject {
        /// Starts the microphone. `buffers` gets its audio on an audio thread; `changed` runs on the main thread when
        /// the device or its format changed and the input stopped by itself. Throws when it can't start.
        func start(
            buffers: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            changed: @escaping @MainActor @Sendable () -> Void) throws

        func stop()
    }

    /// The Mac's current input device, through AVAudioEngine. Each start makes a new engine, so after a device change
    /// it follows the new default device.
    public final class EngineInput: Input {
        private var engine: AVAudioEngine?
        private var observer: NSObjectProtocol?

        public init() {}

        deinit {
            stop()
        }

        public func start(
            buffers: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            changed: @escaping @MainActor @Sendable () -> Void
        ) throws {
            stop()
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            // With no input device the format is empty, and a tap on it would raise an exception.
            guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }

            // 100 ms, the shortest buffer a tap delivers.
            let frames = AVAudioFrameCount(format.sampleRate / 10)
            node.installTap(onBus: 0, bufferSize: frames, format: format) { buffer, _ in
                buffers(buffer)
            }

            // Posted on the engine's own queue, where the engine mustn't be torn down: go to the main thread.
            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        changed()
                    }
                }
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                NotificationCenter.default.removeObserver(observer)
                node.removeTap(onBus: 0)
                throw error
            }

            self.engine = engine
            self.observer = observer
        }

        public func stop() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }

            observer = nil
            guard let engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }
}

extension AudioCapture {
    /// Turns the microphone's buffers into 16 kHz mono Float32: the channels are averaged, then AVAudioConverter
    /// changes the rate, keeping its state from one buffer to the next so the audio has no seams.
    public final class Converter {
        public let inputFormat: AVAudioFormat
        private let monoFormat: AVAudioFormat
        private let outputFormat: AVAudioFormat
        /// Nil when the input is already 16 kHz.
        private let resampler: AVAudioConverter?

        /// Nil for a format it can't convert: no channels, no rate, or samples that are neither Float32 nor Int16.
        public init?(inputFormat: AVAudioFormat) {
            let sampleRate = Double(AudioCapture.sampleRate)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  inputFormat.commonFormat == .pcmFormatFloat32 || inputFormat.commonFormat == .pcmFormatInt16,
                  let mono = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1,
                      interleaved: false),
                  let output = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
            else { return nil }

            if inputFormat.sampleRate == sampleRate {
                resampler = nil
            } else {
                guard let resampler = AVAudioConverter(from: mono, to: output) else { return nil }
                self.resampler = resampler
            }

            self.inputFormat = inputFormat
            monoFormat = mono
            outputFormat = output
        }

        /// Whether buffers in `format` can go through this converter.
        public func accepts(_ format: AVAudioFormat) -> Bool {
            format.sampleRate == inputFormat.sampleRate && format.channelCount == inputFormat.channelCount
                && format.commonFormat == inputFormat.commonFormat && format.isInterleaved == inputFormat.isInterleaved
        }

        /// The buffer's audio at 16 kHz, mono. The resampler holds back a few samples (under a millisecond) until the
        /// next buffer comes; `flush()` gives them up.
        public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
            let mono = Converter.mono(buffer)
            guard let resampler else { return mono }
            // 10 ms at a time: given a whole 100 ms tap buffer at once, AVAudioConverter keeps up to 4,096 input frames
            // (85 ms at 48 kHz) for the next one; given 10 ms, it keeps a few samples.
            let piece = max(Int(monoFormat.sampleRate) / 100, 1)
            var samples: [Float] = []
            var start = 0
            while start < mono.count {
                let end = min(start + piece, mono.count)
                samples += resample(mono[start..<end], with: resampler)
                start = end
            }

            return samples
        }

        /// The samples the resampler still holds, at the end of the audio. The converter starts afresh after it.
        func flush() -> [Float] {
            guard let resampler else { return [] }
            let samples = drain(resampler, expecting: Int(monoFormat.sampleRate)) { inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            resampler.reset()
            return samples
        }

        private func resample(_ piece: ArraySlice<Float>, with resampler: AVAudioConverter) -> [Float] {
            guard let input = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(piece.count)),
                  let inputSamples = input.floatChannelData?[0]
            else { return [] }
            piece.withUnsafeBufferPointer { inputSamples.update(from: $0.baseAddress!, count: $0.count) }
            input.frameLength = AVAudioFrameCount(piece.count)

            var given = false
            return drain(resampler, expecting: piece.count) { inputStatus in
                if given {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                given = true
                inputStatus.pointee = .haveData
                return input
            }
        }

        /// Runs the resampler until it has nothing more to give. Its output buffer is about the size this input should
        /// make; a buffer it fills ("have data") means more is ready now.
        private func drain(
            _ resampler: AVAudioConverter, expecting inputFrames: Int,
            input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
        ) -> [Float] {
            let expected = Double(inputFrames) * outputFormat.sampleRate / monoFormat.sampleRate
            let capacity = AVAudioFrameCount(expected.rounded(.up)) + 64
            var samples: [Float] = []
            for _ in 0..<64 {
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }
                var error: NSError?
                let status = resampler.convert(to: output, error: &error) { _, inputStatus in input(inputStatus) }
                guard status != .error, error == nil, let data = output.floatChannelData?[0] else { break }
                samples += UnsafeBufferPointer(start: data, count: Int(output.frameLength))
                if status != .haveData || output.frameLength == 0 {
                    break
                }
            }

            return samples
        }

        /// The average of the buffer's channels, from Float32 or Int16 samples, interleaved or not.
        static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            let step = buffer.stride
            guard frames > 0, channels > 0 else { return [] }
            if let data = buffer.floatChannelData {
                return mix(frames: frames, channels: channels) { channel, frame in data[channel][frame * step] }
            }

            if let data = buffer.int16ChannelData {
                return mix(frames: frames, channels: channels) { channel, frame in
                    Float(data[channel][frame * step]) / 32_768
                }
            }

            return []
        }

        private static func mix(frames: Int, channels: Int, sample: (Int, Int) -> Float) -> [Float] {
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += sample(channel, frame)
                }

                mono[frame] = channels == 1 ? sum : sum / Float(channels)
            }

            return mono
        }
    }

    /// Cuts the converted samples into chunks of one size; the samples left over wait for the next ones.
    public struct Chunker: Sendable {
        public let size: Int
        private var pending: [Float] = []

        public init(size: Int = AudioCapture.chunkSamples) {
            precondition(size > 0, "A chunk holds at least one sample")
            self.size = size
        }

        /// The chunks `samples` complete, in order.
        public mutating func add(_ samples: [Float]) -> [Chunk] {
            var chunks: [Chunk] = []
            var next = 0
            if !pending.isEmpty {
                next = min(size - pending.count, samples.count)
                pending += samples[0..<next]
                if pending.count < size {
                    return chunks
                }

                chunks.append(Chunk(samples: pending))
                pending.removeAll(keepingCapacity: true)
            }

            while samples.count - next >= size {
                chunks.append(Chunk(samples: Array(samples[next..<next + size])))
                next += size
            }

            pending += samples[next...]
            return chunks
        }

        /// Drops the samples waiting for a chunk.
        public mutating func reset() {
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// Tells when macOS has cut the app off the microphone (PLAN 3.6): exact digital silence (all-zero samples) for
    /// more than 1 s from the start, or for 3 s later on. Real rooms are never exactly silent; a muted or lost input, a
    /// call, or a missing Microphone permission sends zeros. The port of the Windows app's `SilenceWatch`; the host
    /// keeps one per dictation.
    public struct SilenceWatch: Sendable {
        public let sampleRate: Int
        private var heard = 0
        private var zeroRun = 0
        private var silentSoFar = true

        /// The microphone sends only zeros now.
        public private(set) var isSilent = false

        public init(sampleRate: Int = AudioCapture.sampleRate) {
            self.sampleRate = sampleRate
        }

        /// Adds the latest samples; true when `isSilent` changed.
        public mutating func add(_ samples: [Float]) -> Bool {
            for sample in samples {
                if sample == 0 {
                    zeroRun += 1
                } else {
                    zeroRun = 0
                    silentSoFar = false
                }
            }

            heard += samples.count
            let silent = (silentSoFar && heard > sampleRate) || zeroRun > sampleRate * 3
            if silent == isSilent {
                return false
            }

            isSilent = silent
            return true
        }
    }

    /// The conversion and the chunks behind a lock: buffers arrive on the capture thread, starts and stops come from
    /// the main thread. Each start of the input has its own generation, so buffers from an input already stopped are
    /// dropped.
    final class Pipeline: @unchecked Sendable {
        private let lock = NSLock()
        private var converter: Converter?
        private var chunker: Chunker
        private var handler: (@Sendable (Chunk) -> Void)?
        private var current = 0

        init(chunkSamples: Int) {
            chunker = Chunker(size: chunkSamples)
        }

        var onChunk: (@Sendable (Chunk) -> Void)? {
            get { locked { handler } }
            set { locked { handler = newValue } }
        }

        var generation: Int {
            locked { current }
        }

        /// A new capture: nothing carries over.
        func begin() {
            locked {
                current += 1
                converter = nil
                chunker.reset()
            }
        }

        /// The input starts again after a device change: a new converter, but the samples waiting for a chunk stay.
        func restart() {
            locked {
                current += 1
                converter = nil
            }
        }

        func end() {
            locked {
                current += 1
                converter = nil
                chunker.reset()
            }
        }

        /// The capture thread: converts `buffer` and sends the chunks it completes.
        func add(_ buffer: AVAudioPCMBuffer, generation: Int) {
            let (chunks, handler): ([Chunk], (@Sendable (Chunk) -> Void)?) = locked {
                guard generation == current else { return ([], nil) }
                if converter.map({ !$0.accepts(buffer.format) }) ?? true {
                    converter = Converter(inputFormat: buffer.format)
                }

                guard let active = converter else { return ([], nil) }
                return (chunker.add(active.convert(buffer)), self.handler)
            }

            for chunk in chunks {
                handler?(chunk)
            }
        }

        private func locked<Value>(_ body: () -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
}
