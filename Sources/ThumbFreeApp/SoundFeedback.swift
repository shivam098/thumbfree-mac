import AVFoundation
import Foundation

/// Short, quiet tones when recording starts and stops, so you know you were heard: the same notes as
/// thumbfree-windows `SoundFeedback`, made the same way. Pure tones aren't speech, so the voice-activity model drops
/// them if the microphone picks them up.
public final class SoundFeedback: @unchecked Sendable {
    public enum Cue: Sendable {
        case wake
        case startTyping
        case stopTyping
        case standby
    }

    static let rate = 22_050

    private let lock = NSLock()
    private var isEnabled: Bool
    private var player: AVAudioPlayer?

    public init(enabled: Bool) {
        isEnabled = enabled
    }

    /// "Sounds" in Settings; a change applies to the next tone.
    public var enabled: Bool {
        get { lock.withLock { isEnabled } }
        set { lock.withLock { isEnabled = newValue } }
    }

    public func play(_ cue: Cue) {
        guard enabled else { return }
        do {
            let player = try AVAudioPlayer(data: Self.wav(Self.render(Self.notes(cue))))
            lock.withLock {
                self.player?.stop()
                self.player = player
            }

            _ = player.play()
        } catch {
            Log.warn("sound feedback failed: \(Log.kind(of: error))")
        }
    }

    public func close() {
        lock.withLock {
            player?.stop()
            player = nil
        }
    }

    /// Each cue's notes: their pitch and length.
    static func notes(_ cue: Cue) -> [(hz: Double, ms: Int)] {
        switch cue {
        case .wake: return [(660, 70), (880, 90)]
        case .startTyping: return [(880, 110)]
        case .stopTyping: return [(880, 70), (660, 90)]
        case .standby: return [(520, 80)]
        }
    }

    /// The notes as 16-bit samples at `rate`, kept low, each faded in and out over 8 ms so it doesn't click.
    static func render(_ notes: [(hz: Double, ms: Int)]) -> [Int16] {
        var samples: [Int16] = []
        for (hz, ms) in notes {
            let count = rate * ms / 1000
            for i in 0..<count {
                let envelope = min(1.0, Double(min(i, count - i)) / (Double(rate) * 0.008))
                let wave = sin(2 * Double.pi * hz * Double(i) / Double(rate))
                samples.append(Int16(wave * envelope * 0.12 * Double(Int16.max)))
            }
        }

        return samples
    }

    /// `samples` as a mono 16-bit WAV file at `rate`.
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func add<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        add(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        add(UInt32(16))
        add(UInt16(1))
        add(UInt16(1))
        add(UInt32(rate))
        add(UInt32(rate * 2))
        add(UInt16(2))
        add(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        add(UInt32(bytes))
        for sample in samples {
            add(sample)
        }

        return data
    }
}
