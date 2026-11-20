import AVFoundation
import CoreAudio
import XCTest
@testable import ThumbFreeMac

/// A microphone the tests speak into: it hands made-up buffers to the capture, as AVAudioEngine's tap would.
final class FakeAudioInput: AudioCapture.Input, @unchecked Sendable {
    /// Thrown by the next start.
    var failNextStart: Error?
    private(set) var starts = 0
    private(set) var stops = 0
    private var buffers: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Each successful start's `changed`, in order.
    private var changes: [@MainActor @Sendable () -> Void] = []

    func start(
        buffers: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        changed: @escaping @MainActor @Sendable () -> Void
    ) throws {
        starts += 1
        if let error = failNextStart {
            failNextStart = nil
            throw error
        }

        self.buffers = buffers
        changes.append(changed)
    }

    /// Keeps the callbacks, like a tap whose last buffer is still on its way.
    func stop() {
        stops += 1
    }

    func speak(_ buffer: AVAudioPCMBuffer) {
        buffers?(buffer)
    }

    /// The device changed: the latest start hears it, or the one given (a notice that comes after a restart).
    @MainActor
    func changeDevice(start: Int? = nil) {
        guard !changes.isEmpty else { return }
        changes[start ?? changes.count - 1]()
    }
}

/// The chunks a capture sends, from whatever thread.
private final class ReceivedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AudioCapture.Chunk] = []

    var all: [AudioCapture.Chunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }

    func add(_ chunk: AudioCapture.Chunk) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
    }
}

/// A buffer in the engine's own format (Float32), each sample from `sample(channel, frame)`.
private func floatBuffer(
    rate: Double, channels: AVAudioChannelCount = 1, frames: Int, interleaved: Bool = false,
    sample: (Int, Int) -> Float
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData!
    for frame in 0..<frames {
        for channel in 0..<Int(channels) {
            data[channel][frame * buffer.stride] = sample(channel, frame)
        }
    }

    return buffer
}

/// `seconds` of a 440 Hz tone at `amplitude` on every channel, in buffers of 100 ms.
private func tone(rate: Double, channels: AVAudioChannelCount, seconds: Int, amplitude: Float) -> [AVAudioPCMBuffer] {
    let frames = Int(rate) / 10
    return (0..<seconds * 10).map { index in
        floatBuffer(rate: rate, channels: channels, frames: frames) { _, frame in
            let time = Double(index * frames + frame) / rate
            return amplitude * Float(sin(2 * Double.pi * 440 * time))
        }
    }
}

private func rms(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

final class AudioCaptureTests: XCTestCase {
    // MARK: The silent microphone, from thumbfree-windows DictationHostTests.cs

    func testExactSilenceMeansTheMicrophoneWasCutOffUntilSoundComesBack() {
        var watch = AudioCapture.SilenceWatch(sampleRate: 16_000)
        XCTAssertFalse(watch.add([Float](repeating: 0, count: 16_000)))
        XCTAssertTrue(watch.add([Float](repeating: 0, count: 800)))
        XCTAssertTrue(watch.isSilent)
        XCTAssertTrue(watch.add([0.01]))
        XCTAssertFalse(watch.isSilent)
        XCTAssertFalse(watch.add([Float](repeating: 0, count: 48_000)))
        XCTAssertTrue(watch.add([Float](repeating: 0, count: 100)))
        XCTAssertTrue(watch.isSilent)
    }

    // MARK: Chunks

    func testChunksAreFilledAcrossBuffersAndTheRestWaits() {
        var chunker = AudioCapture.Chunker(size: 4)

        XCTAssertEqual([], chunker.add([1, 2, 3]))
        XCTAssertEqual([[1, 2, 3, 4], [5, 6, 7, 8]], chunker.add([4, 5, 6, 7, 8, 9]).map(\.samples))
        XCTAssertEqual([], chunker.add([]))
        XCTAssertEqual([[9, 10, 11, 12]], chunker.add([10, 11, 12]).map(\.samples))
        XCTAssertEqual([], chunker.add([13]))
        chunker.reset()
        XCTAssertEqual([[20, 21, 22, 23]], chunker.add([20, 21, 22, 23]).map(\.samples))
    }

    func testEachChunkCarriesItsLevel() {
        var chunker = AudioCapture.Chunker()
        let quiet = [Float](repeating: 0.0005, count: 480)
        let loud = [Float](repeating: 0.5, count: 480)

        let chunks = chunker.add(quiet + loud)

        XCTAssertEqual([0, 1], chunks.map(\.level))
    }

    // MARK: Conversion

    func testA48kHzStereoMicrophoneBecomes16kHzMono() {
        let buffers = tone(rate: 48_000, channels: 2, seconds: 1, amplitude: 0.5)
        let converter = AudioCapture.Converter(inputFormat: buffers[0].format)!
        let output = buffers.flatMap { converter.convert($0) }
        let rest = converter.flush()

        // Nothing is lost: a second of audio, of which the resampler held back under 10 ms for the next buffer.
        XCTAssertEqual(16_000, output.count + rest.count)
        XCTAssertLessThan(rest.count, 160)
        XCTAssertEqual(0.5 / Float(2).squareRoot(), rms(output[160...]), accuracy: 0.02)
    }

    func testA44_1kHzMicrophoneBecomes16kHz() {
        let buffers = tone(rate: 44_100, channels: 1, seconds: 1, amplitude: 0.25)
        let converter = AudioCapture.Converter(inputFormat: buffers[0].format)!
        let output = buffers.flatMap { converter.convert($0) }
        let rest = converter.flush()

        XCTAssertEqual(16_000, output.count + rest.count)
        XCTAssertLessThan(rest.count, 160)
        XCTAssertEqual(0.25 / Float(2).squareRoot(), rms(output[160...]), accuracy: 0.02)
    }

    func testChannelsAreAveragedAnd16kHzPassesThrough() {
        let stereo = floatBuffer(rate: 16_000, channels: 2, frames: 3) { channel, frame in
            channel == 0 ? 0.2 * Float(frame) : 0.4 * Float(frame)
        }
        let interleaved = floatBuffer(rate: 16_000, channels: 2, frames: 3, interleaved: true) { channel, _ in
            channel == 0 ? -0.5 : 0.25
        }

        let fromStereo = AudioCapture.Converter(inputFormat: stereo.format)!.convert(stereo)
        let fromInterleaved = AudioCapture.Converter(inputFormat: interleaved.format)!.convert(interleaved)

        XCTAssertEqual(3, fromStereo.count)
        for (expected, sample) in zip([Float(0), 0.3, 0.6], fromStereo) {
            XCTAssertEqual(expected, sample, accuracy: 0.000_01)
        }

        XCTAssertEqual([-0.125, -0.125, -0.125], fromInterleaved)
    }

    func testInt16SamplesAreScaledLikeTheWindowsMicrophone() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        buffer.int16ChannelData![0][0] = 16_384
        buffer.int16ChannelData![0][1] = -32_768
        buffer.int16ChannelData![0][2] = 0

        XCTAssertEqual([0.5, -1, 0], AudioCapture.Converter(inputFormat: format)!.convert(buffer))
    }

    // MARK: The capture

    @MainActor
    func testTheCaptureSendsChunksOfWhatTheMicrophoneHears() throws {
        let input = FakeAudioInput()
        let capture = AudioCapture(input: input)
        let received = ReceivedChunks()
        capture.onChunk = { chunk in received.add(chunk) }

        try capture.start()
        XCTAssertTrue(capture.isRunning)
        let speech = floatBuffer(rate: 16_000, frames: 1_000) { _, frame in Float(frame) / 1_000 }
        input.speak(speech)
        input.speak(floatBuffer(rate: 16_000, frames: 500) { _, frame in Float(1_000 + frame) / 1_000 })

        let chunks = received.all
        XCTAssertEqual([480, 480, 480], chunks.map(\.samples.count))
        XCTAssertEqual((0..<1_440).map { Float($0) / 1_000 }, chunks.flatMap(\.samples))

        capture.stop()
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(1, input.stops)
        // A buffer still on its way when the microphone stopped is dropped.
        input.speak(speech)
        XCTAssertEqual(3, received.all.count)
    }

    /// Each chunk's level is the mono mix's: a microphone on input 1 of a two-input interface reads 6 dB quieter.
    @MainActor
    func testTheLevelIsTakenFromTheMonoMix() throws {
        let input = FakeAudioInput()
        let capture = AudioCapture(input: input)
        let received = ReceivedChunks()
        capture.onChunk = { chunk in received.add(chunk) }
        try capture.start()

        // About -30 dBFS on input 1 and silence on input 2 mix to -36 dBFS: halfway up the meter.
        let mixed = Float(pow(10, -36.0 / 20))
        input.speak(floatBuffer(rate: 16_000, channels: 2, frames: 480) { channel, _ in channel == 0 ? 2 * mixed : 0 })
        capture.stop()

        let chunk = try XCTUnwrap(received.all.first)
        XCTAssertEqual(1, received.all.count)
        XCTAssertEqual(0.5, chunk.level, accuracy: 0.000_1)
    }

    @MainActor
    func testADeviceChangeRestartsTheCaptureOnTheNewFormat() throws {
        let input = FakeAudioInput()
        let capture = AudioCapture(input: input)
        let received = ReceivedChunks()
        capture.onChunk = { chunk in received.add(chunk) }
        try capture.start()
        input.speak(floatBuffer(rate: 16_000, frames: 600) { _, _ in 0.1 })
        XCTAssertEqual(1, received.all.count)

        input.changeDevice()

        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(2, input.starts)
        XCTAssertEqual(1, input.stops)
        // The new microphone is 48 kHz stereo; the 120 samples left from the old one are kept.
        let newMicrophone = tone(rate: 48_000, channels: 2, seconds: 1, amplitude: 0.5)
        let reference = AudioCapture.Converter(inputFormat: newMicrophone[0].format)!
        let converted = newMicrophone.reduce(0) { $0 + reference.convert($1).count }
        for buffer in newMicrophone {
            input.speak(buffer)
        }

        let chunks = received.all
        XCTAssertEqual(1 + (120 + converted) / 480, chunks.count)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count == 480 })
        XCTAssertEqual(Array(repeating: Float(0.1), count: 120), Array(chunks[1].samples[0..<120]))
    }

    @MainActor
    func testAMicrophoneThatCannotStartAgainIsReported() throws {
        let input = FakeAudioInput()
        let capture = AudioCapture(input: input)
        var failures: [AudioCapture.Failure] = []
        capture.onFailure = { error in failures.append(error as? AudioCapture.Failure ?? .noMicrophone) }
        try capture.start()

        input.failNextStart = AudioCapture.Failure.noMicrophone
        input.changeDevice()

        XCTAssertEqual([.noMicrophone], failures)
        XCTAssertFalse(capture.isRunning)
        // A change reported by an input already stopped is ignored.
        input.changeDevice()
        XCTAssertEqual(2, input.starts)
    }

    @MainActor
    func testStartFailsWithoutAMicrophone() {
        let input = FakeAudioInput()
        input.failNextStart = AudioCapture.Failure.noMicrophone
        let capture = AudioCapture(input: input)

        XCTAssertThrowsError(try capture.start()) { error in
            XCTAssertEqual(.noMicrophone, error as? AudioCapture.Failure)
        }
        XCTAssertFalse(capture.isRunning)
    }

    /// A new default input with a new rate: Core Audio and the engine both say so, and the later notice reaches the
    /// capture after it has already started again.
    @MainActor
    func testTwoNoticesOfOneDeviceChangeRestartOnce() throws {
        let input = FakeAudioInput()
        let capture = AudioCapture(input: input)
        try capture.start()

        input.changeDevice()
        input.changeDevice(start: 0)

        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(2, input.starts)
        XCTAssertEqual(1, input.stops)
    }

    /// Core Audio calls the listener on a thread of its own: it reaches the main thread until `stop()`, which takes it
    /// off Core Audio.
    @MainActor
    func testTheDefaultInputListenerReachesTheMainThreadUntilStopped() throws {
        let watcher = AudioCapture.DefaultInputWatcher()
        let calls = MainThreadCalls()
        guard watcher.start({ calls.record() }) else {
            throw XCTSkip("Core Audio took no listener on this machine")
        }

        let id = try XCTUnwrap(watcher.id)
        notifyAsCoreAudio(id)
        XCTAssertEqual(1, calls.count)
        XCTAssertTrue(calls.onMainThread)

        XCTAssertTrue(watcher.stop())
        // A call already on its way when the listener came off finds nothing.
        notifyAsCoreAudio(id)
        XCTAssertEqual(1, calls.count)
        XCTAssertFalse(watcher.stop())
    }

    /// Calls the listener the way Core Audio does, from another thread, then lets the main queue run.
    @MainActor
    private func notifyAsCoreAudio(_ id: Int) {
        let notified = expectation(description: "notified")
        DispatchQueue.global().async {
            var address = AudioCapture.DefaultInputWatcher.address
            _ = AudioCapture.DefaultInputWatcher.callback(
                AudioCapture.DefaultInputWatcher.system, 1, &address, UnsafeMutableRawPointer(bitPattern: id))
            DispatchQueue.main.async {
                notified.fulfill()
            }
        }
        wait(for: [notified], timeout: 2)
    }
}

@MainActor
private final class MainThreadCalls {
    private(set) var count = 0
    private(set) var onMainThread = true

    func record() {
        count += 1
        onMainThread = onMainThread && Thread.isMainThread
    }
}
