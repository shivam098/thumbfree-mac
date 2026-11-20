import CWhisper
import Dispatch
import Foundation

extension ThumbFreeSpeech {
    /// Gets ggml, the engine under whisper.cpp, ready in the background before the first speech detector or Whisper
    /// model needs it. ggml's first use finds its devices, and making the Metal device compiles all of ggml's shaders
    /// (they're built in as source): seconds on a Mac, about 20 s on CI's virtual GPU, and they stay in memory. Silero
    /// runs on the CPU but waits for this too. Only worth it when the chosen model uses Silero or Whisper (see
    /// `ThumbFreeSpeech`). It runs once per process, at utility priority; calling this again doesn't start it again.
    /// `done`, if given, is called on a background queue once it has finished (straight away if it has).
    public static func warmUp(then done: (@Sendable () -> Void)? = nil) {
        Ggml.warmUp(then: done)
    }

    /// `warmUp`, returning once it has finished.
    public static func waitForWarmUp() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Ggml.warmUp { continuation.resume() }
        }
    }

    /// Whether the warm-up has finished, so a speech detector or Whisper model is made without waiting for it.
    public static var isWarmedUp: Bool { Ggml.runs > 0 }
}

/// ggml's one-time setup (`ThumbFreeSpeech.warmUp`).
enum Ggml {
    /// Serial and of utility priority: what's queued after the warm-up runs once it has finished, and a `sync` from a
    /// thread of higher priority raises the warm-up's priority while it waits.
    private static let queue = DispatchQueue(label: "ThumbFreeSpeech.ggml", qos: .utility)
    private static let counter = Counter()

    /// Queues the warm-up the first time it's read. Counting the devices makes ggml's device registry: the CPU,
    /// Accelerate, and Metal with its shaders.
    private static let started: Void = queue.async {
        _ = quietWhisperLogs
        _ = ggml_backend_dev_count()
        counter.add()
    }

    /// How many times the warm-up has run: 0, then 1.
    static var runs: Int { counter.value }

    static func warmUp(then done: (@Sendable () -> Void)?) {
        _ = started
        guard let done else { return }
        queue.async { DispatchQueue.global(qos: .utility).async(execute: done) }
    }

    /// Returns once the warm-up has finished, starting it if nothing has. Every whisper.cpp object is made after this.
    static func wait() {
        _ = started
        queue.sync {}
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func add() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }
}
