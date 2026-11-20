import Foundation
import ThumbFreeCore
import ThumbFreeSpeech

/// All speech recognition runs here, one job at a time on one queue, as in the Android app's SpeechEngine and
/// thumbfree-windows `SpeechThread`: the models aren't thread-safe. A model loads when a dictation first needs it and
/// stays loaded until `unloadAll` (the host calls it after a few idle minutes, PLAN 3.1).
final class SpeechThread: @unchecked Sendable {
    let models: SpeechModels

    private let queue = DispatchQueue(label: "app.thumbfree.mac.speech", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false

    /// Speech thread only.
    private var loaded: [String: Recognizer] = [:]

    init(_ models: SpeechModels) {
        self.models = models
    }

    /// Queues a job; it runs after every job queued before it. What it throws is logged.
    func post(_ job: @escaping () throws -> Void) {
        guard !isClosed else { return }
        queue.async {
            do {
                try job()
            } catch {
                Log.error("speech job failed: \(Log.kind(of: error))")
            }
        }
    }

    /// Queues a job and hands back its result, which is cancelled when ThumbFree is shutting down.
    func run<T>(_ job: @escaping () -> T) -> Pending<T> {
        let pending = Pending<T>()
        guard !isClosed else {
            pending.cancel()
            return pending
        }

        queue.async { pending.resolve(job()) }
        return pending
    }

    /// Speech thread: the recognizer for `spec`, loaded if needed. Other models are unloaded first, except `keep`, so
    /// at most two are in memory (a model and the one that previews for it).
    func model(_ spec: ModelSpec, threads: Int, keep: ModelSpec? = nil) throws -> Recognizer {
        if let model = loaded[spec.id] {
            return model
        }

        for id in loaded.keys.sorted() where id != keep?.id {
            unload(id)
        }

        let started = ProcessInfo.processInfo.systemUptime
        let model = try models.load(spec, threads: threads)
        loaded[spec.id] = model
        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Log.info("model \(spec.id) loaded in \(ms) ms (\(threads) threads)")
        return model
    }

    /// Speech thread: frees every model.
    func unloadAll() {
        for id in loaded.keys.sorted() {
            unload(id)
        }
    }

    /// Lets the jobs queued so far finish (5 s at most), then frees the models. Jobs queued later are dropped.
    func close() {
        let first: Bool = lock.withLock {
            defer { closed = true }
            return !closed
        }

        guard first else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            unloadAll()
            models.close()
            done.signal()
        }

        if done.wait(timeout: .now() + 5) == .timedOut {
            // Freeing a model in the middle of a transcription would crash; it's freed once that's over.
            Log.warn("speech thread still busy at exit; the models are freed when it's done")
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    private func unload(_ id: String) {
        loaded.removeValue(forKey: id)?.close()
        Log.info("model \(id) unloaded")
    }
}
