import Foundation

/// Loudness of microphone audio for the level meter shown while recording.
public enum AudioLevel {
    private static let floorDb = -60.0
    private static let ceilingDb = -12.0

    /// 0 for silence (at or below -60 dBFS) up to 1 for loud speech (-12 dBFS and above), from the RMS.
    public static func of(_ samples: some Collection<Float>) -> Float {
        if samples.isEmpty {
            return 0
        }

        var sum = 0.0
        for sample in samples {
            // As in C#: the square in single precision, the sum in double.
            sum += Double(sample * sample)
        }

        let rms = (sum / Double(samples.count)).squareRoot()
        if rms <= 0 {
            return 0
        }

        let level = (20 * log10(rms) - floorDb) / (ceilingDb - floorDb)
        return Float(level < 0 ? 0 : level > 1 ? 1 : level)
    }
}
