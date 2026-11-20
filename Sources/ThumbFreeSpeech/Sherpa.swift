import CSherpaOnnx
import Foundation

/// Small guards around sherpa-onnx's C API, whose failures would otherwise crash the process later.
enum Sherpa {
    /// Full paths of `names` in `directory`; throws if one is missing (as Android does).
    static func requireFiles(_ directory: String, _ names: [String]) throws -> [String] {
        try names.map { name in
            let path = Files.combine(directory, name)
            guard Files.isFile(path) else { throw SpeechError.notFound("Missing \(path)", path) }
            return nativePath(path)
        }
    }

    /// The path as sherpa-onnx gets it. Windows passes an 8.3 short name for a path outside the system code page (the C#
    /// wrapper marshals paths as ANSI); the C API takes UTF-8 and so does the Mac's file system, so here it's the full
    /// path, as on every system but Windows.
    static func nativePath(_ path: String) -> String { Files.fullPath(path) }

    /// sherpa-onnx returns NULL for a configuration it rejects (and logs to stderr, which nobody sees); using it would
    /// crash. Throws instead.
    static func created(_ handle: OpaquePointer?, _ what: String) throws -> OpaquePointer {
        guard let handle else { throw SpeechError.invalidData("sherpa-onnx couldn't load the \(what).") }
        return handle
    }

    /// "2.0.1".
    static var version: String { String(cString: SherpaOnnxGetVersionStr()) }

    /// The onnxruntime linked into sherpa-onnx ("1.28.2").
    static var onnxruntimeVersion: String { String(cString: SherpaOnnxGetOnnxruntimeVersionStr()) }

    /// The C string `text` as a Swift string; "" for NULL.
    static func string(_ text: UnsafePointer<CChar>?) -> String { text.map { String(cString: $0) } ?? "" }
}
