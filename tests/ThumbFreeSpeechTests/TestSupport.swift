import Foundation
import ThumbFreeCore
import XCTest
@testable import ThumbFreeSpeech

/// Models for the tests that need one, looked up like the app does (~/Library/Application Support/ThumbFree/models,
/// then Voice Assistant's folder); THUMBFREE_MODELS points at one folder instead (CI downloads the models there). A
/// test whose model isn't there is skipped, not failed, so `swift test` passes without downloads.
enum TestModels {
    static let store: ModelStore = {
        if let folder = ProcessInfo.processInfo.environment["THUMBFREE_MODELS"], !folder.isEmpty {
            return ModelStore(primaryFolder: folder)
        }

        return ModelStore(primaryFolder: ModelStore.defaultFolder, sharedFolders: ModelStore.defaultSharedFolders)
    }()

    static let threads = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 8)

    /// The C# tests' [ModelFact("id")]: the model, or a skip when it isn't installed.
    static func require(_ id: String) throws -> ModelSpec {
        guard let spec = ModelCatalog.byId(id) else { throw XCTSkip("Unknown model \(id)") }
        guard store.isInstalled(spec) else {
            throw XCTSkip("\(id) isn't in \(store.primaryFolder) (set THUMBFREE_MODELS to a folder that has it)")
        }

        return spec
    }

    /// The path of `file` (Silero, say), or a skip when it isn't installed.
    static func require(_ file: ModelFile) throws -> String {
        guard let path = store.pathOf(file) else {
            throw XCTSkip("\(file.name) isn't in \(store.primaryFolder) (set THUMBFREE_MODELS to a folder that has it)")
        }

        return path
    }
}

/// The speech clips in tests/audio at the repository root (the same in every ThumbFree repo).
enum Audio {
    /// The repository root, found from this file's path: tests/<target>/TestSupport.swift.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func path(_ name: String) -> String { root.appendingPathComponent("tests/audio/\(name)").path }

    static func read(_ name: String) throws -> [Float] { try WavFile.readPcm16Mono16k(path(name)) }

    /// 16 kHz chunks of `ms` milliseconds, as the microphone delivers them.
    static func chunks(_ samples: [Float], ms: Int = 100) -> [[Float]] {
        let size = Decoding.sampleRate * ms / 1000
        return stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min(samples.count, $0 + size)]) }
    }

    static func silence(ms: Int) -> [Float] { [Float](repeating: 0, count: Decoding.sampleRate * ms / 1000) }
}

/// An empty folder in the temporary folder, deleted by `remove`.
final class Scratch {
    let path: String

    init() throws {
        let name = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        path = FileManager.default.temporaryDirectory.appendingPathComponent("thumbfree-speech-tests/\(name)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ relative: String) -> String { (path as NSString).appendingPathComponent(relative) }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A value several threads write and read.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value

    init(_ value: Value) {
        current = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&current)
        lock.unlock()
    }
}

/// Whether `text` contains `part`, ignoring case (C#'s `StringComparison.OrdinalIgnoreCase`).
func containsIgnoringCase(_ text: String?, _ part: String) -> Bool {
    text?.range(of: part, options: .caseInsensitive) != nil
}

/// Whether `text` matches the regular expression `pattern`.
func matchesPattern(_ text: String, _ pattern: String, ignoringCase: Bool = false) -> Bool {
    text.range(of: pattern, options: ignoringCase ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
}

/// Runs `work` and prints how long it took (and the text it returned), so regressions show in the test log.
func timed<Result>(_ label: String, _ work: () throws -> Result) rethrows -> Result {
    let started = Date()
    let result = try work()
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    if let text = result as? String? {
        print("\(label): \(ms) ms: \(text ?? "nil")")
    } else {
        print("\(label): \(ms) ms")
    }

    return result
}
