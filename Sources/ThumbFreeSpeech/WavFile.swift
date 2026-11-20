import Foundation

public enum WavFile {
    /// Reads a 16 kHz mono 16-bit PCM WAV file into normalized float samples.
    public static func readPcm16Mono16k(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try data.withUnsafeBytes { bytes -> [Float] in
            var reader = Reader(bytes: bytes)
            guard try reader.tag() == "RIFF" else { throw SpeechError.invalidData("Not a RIFF file.") }
            _ = try reader.uint32()
            guard try reader.tag() == "WAVE" else { throw SpeechError.invalidData("Not a WAVE file.") }

            var channels: Int16 = 0
            var bits: Int16 = 0
            var rate: UInt32 = 0
            while reader.position < bytes.count {
                let id = try reader.tag()
                let size = try Int(reader.uint32())
                if id == "fmt " {
                    let format = try reader.int16()
                    channels = try reader.int16()
                    rate = try reader.uint32()
                    _ = try reader.uint32()
                    _ = try reader.int16()
                    bits = try reader.int16()
                    reader.position += max(size - 16, 0)
                    if format != 1 {
                        throw SpeechError.invalidData("Only PCM WAV is supported.")
                    }
                } else if id == "data" {
                    if channels != 1 || rate != 16000 || bits != 16 {
                        throw SpeechError.invalidData(
                            "Expected 16 kHz mono 16-bit, got \(rate) Hz \(channels) ch \(bits)-bit.")
                    }

                    let count = size / 2
                    let start = try reader.skip(count * 2)
                    return (0..<count).map { i in
                        Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: start + i * 2, as: Int16.self)))
                            / 32768
                    }
                } else {
                    reader.position += size + (size & 1)
                }
            }

            throw SpeechError.invalidData("WAV has no data chunk.")
        }
    }

    /// Little-endian reads that fail past the end, like .NET's `BinaryReader`.
    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var position = 0

        mutating func tag() throws -> String {
            let start = try skip(4)
            return String(decoding: bytes[start..<start + 4], as: UTF8.self)
        }

        mutating func int16() throws -> Int16 {
            let start = try skip(2)
            return Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: Int16.self))
        }

        mutating func uint32() throws -> UInt32 {
            let start = try skip(4)
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: UInt32.self))
        }

        /// Moves past the next `count` bytes and returns where they start.
        mutating func skip(_ count: Int) throws -> Int {
            guard position + count <= bytes.count else {
                throw SpeechError.invalidData("Unable to read beyond the end of the stream.")
            }

            defer { position += count }
            return position
        }
    }
}
