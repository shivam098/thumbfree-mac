import Compression
import Foundation

/// A zip of files, for sharing samples (.NET's ZipFile, which Foundation lacks on the Mac): each file deflated (or
/// stored, when deflating doesn't make it smaller), with its time and a UTF-8 name, written one file at a time.
enum ZipArchive {
    struct TooBig: Error {}

    /// Writes a zip at `path` holding each file under its name ("20261119-180000-000/audio.wav").
    static func write(_ path: String, _ entries: [(name: String, file: String)]) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }

        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? output.close() }
        var offset = 0
        var directory = Data()
        for entry in entries {
            // A zip without its 64-bit extension holds files under 4 GB: asked before reading, so a bigger one is
            // never read into memory.
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.file)
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) <= Int64(UInt32.max) else { throw TooBig() }
            let contents = try Data(contentsOf: URL(fileURLWithPath: entry.file))
            let modified = attributes[.modificationDate] as? Date
            let (time, date) = dosTime(modified ?? Date())
            let crc = crc32(contents)
            let deflated = deflate(contents)
            let data = deflated ?? contents
            let name = Data(entry.name.utf8)
            guard contents.count <= Int(UInt32.max), offset + 30 + name.count + data.count <= Int(UInt32.max) else {
                throw TooBig()
            }

            // What the local header and the directory entry share: the method (8 deflated, 0 stored), the time, the
            // checksum, the sizes and the name's length, with bit 11 for a UTF-8 name.
            var common = Data()
            common.append16(0x0800)
            common.append16(deflated == nil ? 0 : 8)
            common.append16(time)
            common.append16(date)
            common.append32(crc)
            common.append32(UInt32(data.count))
            common.append32(UInt32(contents.count))
            common.append16(UInt16(name.count))
            common.append16(0)

            var local = Data()
            local.append32(0x0403_4B50)
            local.append16(20)
            local.append(common)
            local.append(name)
            try output.write(contentsOf: local)
            try output.write(contentsOf: data)

            // Made by Unix (so its permissions, rw-r--r--, are used), version 2.0.
            directory.append32(0x0201_4B50)
            directory.append16(0x0314)
            directory.append16(20)
            directory.append(common)
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append32(UInt32(0o100644) << 16)
            directory.append32(UInt32(offset))
            directory.append(name)
            offset += local.count + data.count
        }

        guard offset + directory.count <= Int(UInt32.max), entries.count <= Int(UInt16.max) else { throw TooBig() }
        var end = Data()
        end.append32(0x0605_4B50)
        end.append16(0)
        end.append16(0)
        end.append16(UInt16(entries.count))
        end.append16(UInt16(entries.count))
        end.append32(UInt32(directory.count))
        end.append32(UInt32(offset))
        end.append16(0)
        try output.write(contentsOf: directory)
        try output.write(contentsOf: end)
    }

    /// The zip's CRC-32 of `data`.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }

        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }

        return c
    }

    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB, RFC 1951), as a zip holds it; nil when it isn't smaller.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var output = Data(count: data.count)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = destination.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(to, destination.count, from, source.count, nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0, written < data.count else { return nil }
        output.count = written
        return output
    }

    /// MS-DOS's time and date, in local time, as zips keep them.
    private static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let local = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = min(max(local.year ?? 1980, 1980), 2107)
        let time = (local.hour ?? 0) << 11 | (local.minute ?? 0) << 5 | (local.second ?? 0) / 2
        let day = (year - 1980) << 9 | (local.month ?? 1) << 5 | (local.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
