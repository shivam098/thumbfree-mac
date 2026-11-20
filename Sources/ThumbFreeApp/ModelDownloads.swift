import Foundation
import ThumbFreeCore
import ThumbFreeSpeech

/// Speech models on this Mac, as the menu bar (and the window, in phase 4) sees them (thumbfree-windows
/// `IModelManager`). `StoreModelManager` is the model store's; the app goes through `ModelDownloads`.
public protocol ModelManager: AnyObject {
    /// Runs (on any thread) when a model appears or goes, as when the host downloaded it.
    var onChange: ((ModelSpec) -> Void)? { get set }

    /// Every file of the model is on this Mac, complete.
    func isInstalled(_ spec: ModelSpec) -> Bool

    /// Downloads the model's missing files, reporting progress from 0 to 1, and resumes partial files. Throws
    /// `CancellationError` when its task is cancelled; on any other failure, an error whose description can be shown
    /// as is ("Not enough free space: 661 MB needed, 120 MB free.").
    func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Deletes the model's files (never a copy that Jarvis owns).
    func delete(_ spec: ModelSpec) throws
}

public enum ModelStatus: Sendable {
    case notInstalled
    case downloading
    case installed
}

/// A model's state for the menu bar: `progress` from 0 to 1 while downloading, and the last error, if any.
public struct ModelState: Equatable, Sendable {
    public var status: ModelStatus
    public var progress: Double
    public var error: String?

    public init(_ status: ModelStatus, progress: Double = 0, error: String? = nil) {
        self.status = status
        self.progress = progress
        self.error = error
    }
}

/// Runs model downloads for the whole app (thumbfree-windows `ModelDownloads`): one per model, cancellable, with
/// progress that the menu bar and the pill show. The dictation host starts its downloads here too (`start`). Change
/// handlers run on the `changes` queue.
public final class ModelDownloads: @unchecked Sendable {
    public let models: ModelManager

    private let lock = NSLock()
    private let changes: DispatchQueue?
    private let observers = Observers<ModelSpec>()
    private var running: [String: Running] = [:]
    private var errors: [String: String] = [:]

    /// - Parameter changes: Where change handlers run (the app passes the main queue); nil runs them on the thread
    ///   of the change, as C# does without a UI thread.
    public init(_ models: ModelManager, changes: DispatchQueue? = nil) {
        self.models = models
        self.changes = changes
        models.onChange = { [weak self] spec in
            guard let self else { return }
            self.lock.withLock { self.errors[spec.id] = nil }
            self.raiseChanged(spec)
        }
    }

    /// Runs `handler` with the model after each change: a download started, moved on, ended or failed.
    @discardableResult
    public func observe(_ handler: @escaping (ModelSpec) -> Void) -> ObservationToken {
        observers.add(handler)
    }

    public func state(_ spec: ModelSpec) -> ModelState {
        lock.withLock {
            if let entry = running[spec.id] {
                return ModelState(.downloading, progress: entry.progress)
            }

            if models.isInstalled(spec) {
                return ModelState(.installed, progress: 1)
            }

            return ModelState(.notInstalled, error: errors[spec.id])
        }
    }

    /// Starts downloading (or joins the download already running). The task never fails; it ends when the download
    /// does.
    @discardableResult
    public func start(_ spec: ModelSpec) -> Task<Void, Never> {
        lock.lock()
        if let task = running[spec.id]?.task {
            lock.unlock()
            return task
        }

        if models.isInstalled(spec) {
            lock.unlock()
            return Task {}
        }

        errors[spec.id] = nil
        let entry = Running()
        running[spec.id] = entry
        let task = Task.detached(priority: .utility) { [self] in await self.run(spec, entry) }
        entry.task = task
        lock.unlock()
        raiseChanged(spec)
        return task
    }

    public func cancel(_ spec: ModelSpec) {
        lock.withLock { running[spec.id]?.cancel() }
    }

    /// Stops any download of the model and deletes its files.
    public func delete(_ spec: ModelSpec) {
        let stopping: Task<Void, Never>? = lock.withLock {
            let entry = running[spec.id]
            entry?.cancel()
            errors[spec.id] = nil
            return entry?.task
        }

        guard let stopping else {
            deleteNow(spec)
            return
        }

        Task.detached(priority: .utility) { [self] in
            await stopping.value
            self.deleteNow(spec)
        }
    }

    /// A download's error as people read it: the person's own Cancel isn't one.
    static func describe(_ error: Error) -> String {
        switch error {
        case is CancellationError:
            // Not the person's Cancel: the download stopped by itself.
            return "The download stalled. Try again."
        case is URLError:
            return "Couldn't download it. Check the internet connection, then try again."
        default:
            return error.localizedDescription
        }
    }

    private func deleteNow(_ spec: ModelSpec) {
        do {
            try models.delete(spec)
        } catch {
            Log.warn("model delete failed: \(Log.kind(of: error))")
            lock.withLock { errors[spec.id] = "Couldn't delete it: it may be in use. Try again after dictating." }
        }

        raiseChanged(spec)
    }

    private func run(_ spec: ModelSpec, _ entry: Running) async {
        let lastShown = LockedValue(-1)
        let progress: @Sendable (Double) -> Void = { [self] value in
            let clamped = min(max(value, 0), 1)
            lock.withLock { entry.progress = clamped }
            let shown = Int(clamped * 200)
            if lastShown.exchange(shown) != shown {
                raiseChanged(spec)
            }
        }

        var failure: String?
        do {
            try await models.download(spec, progress: progress)
            Log.info("model \(spec.id) downloaded")
        } catch {
            if error is CancellationError && lock.withLock({ entry.cancelled }) {
                Log.info("model \(spec.id) download cancelled")
            } else {
                Log.warn("model \(spec.id) download failed: \(Log.kind(of: error))")
                failure = Self.describe(error)
            }
        }

        lock.withLock {
            running[spec.id] = nil
            if let failure {
                errors[spec.id] = failure
            }
        }

        raiseChanged(spec)
    }

    private func raiseChanged(_ spec: ModelSpec) {
        observers.notify(spec, on: changes)
    }

    /// A download in progress; its fields are guarded by the downloads' lock.
    private final class Running: @unchecked Sendable {
        var task: Task<Void, Never>?
        var progress: Double = 0
        var cancelled = false

        func cancel() {
            cancelled = true
            task?.cancel()
        }
    }
}

/// The model store's models (thumbfree-windows `StoreModelManager`): resumable downloads pinned by SHA-256 into
/// ~/Library/Application Support/ThumbFree/models, and the models Jarvis already downloaded, read where they are.
public final class StoreModelManager: ModelManager, @unchecked Sendable {
    public let store: ModelStore

    private let changed = Handler<ModelSpec>()

    public init(_ store: ModelStore) {
        self.store = store
    }

    public var onChange: ((ModelSpec) -> Void)? {
        get { changed.handler }
        set { changed.handler = newValue }
    }

    /// The model's files, and Silero for the engines that find pauses with it (Whisper and Parakeet).
    public func isInstalled(_ spec: ModelSpec) -> Bool { StoreSpeechModels.isInstalled(store, spec) }

    /// Whisper and Parakeet find speech with Silero, which is small (885 KB) and comes with the first model that needs
    /// it.
    public func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws {
        if !spec.streaming && !store.isInstalled(ModelCatalog.vad) {
            try await store.download(ModelCatalog.vad)
        }

        try await store.download(spec) { progress($0.fraction) }
        Log.info("model ready: \(spec.id)")
        changed(spec)
    }

    public func delete(_ spec: ModelSpec) throws {
        store.delete(spec)
        Log.info("model deleted: \(spec.id)")
        changed(spec)
    }
}

/// Big models (over 300 MB) ask before downloading (PLAN 3.1): their size, this Mac's memory against what the model
/// needs, and a warning on a metered connection (thumbfree-windows `ModelConsent`).
public enum ModelConsent {
    public static let bigModelBytes: Int64 = 300_000_000

    public static func needed(_ spec: ModelSpec) -> Bool { spec.bytes > bigModelBytes }

    /// "English, accurate" from "English, accurate (slower; needs 6 GB+ memory)".
    public static func shortName(_ spec: ModelSpec) -> String {
        guard let bracket = spec.label.range(of: " ("), bracket.lowerBound > spec.label.startIndex else {
            return spec.label
        }

        return String(spec.label[..<bracket.lowerBound])
    }

    public static func title(_ spec: ModelSpec) -> String { "Download “\(shortName(spec))”?" }

    public static func message(_ spec: ModelSpec, totalMemoryBytes: Int64, metered: Bool) -> String {
        let gb = Int((Double(totalMemoryBytes) / Double(Int64(1) << 30)).rounded(.toNearestOrEven))
        var text = [
            "This model is \(mb(spec.bytes)). It makes the fewest mistakes, but it's slower and needs about ",
            "\(mb(spec.bytes * 3 / 2)) of free memory while you dictate.\n\nThis Mac has \(gb) GB of memory.",
        ].joined()
        if gb < spec.recommendedMemoryGb {
            text += [
                " That may not be enough (\(spec.recommendedMemoryGb) GB or more is best): dictation could be slow, ",
                "and other apps may slow down while it works.",
            ].joined()
        } else {
            text += " That's enough."
        }

        if metered {
            text += [
                "\n\nYou're on a metered connection, so this may use up your data allowance. Wi-Fi or an unmetered ",
                "connection is better.",
            ].joined()
        }

        return text
    }

    /// Sizes the way the Android app shows them: decimal megabytes, rounded.
    public static func mb(_ bytes: Int64) -> String { "\((bytes + 500_000) / 1_000_000) MB" }
}
