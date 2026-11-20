import CryptoKit
import Foundation
import ThumbFreeCore

/// A model's bytes on disk (finished files plus partial downloads) out of its total.
public struct DownloadProgress: Equatable, Sendable {
    public let done: Int64
    public let total: Int64

    public init(done: Int64, total: Int64) {
        self.done = done
        self.total = total
    }

    public var fraction: Double { total <= 0 ? 0 : min(max(Double(done) / Double(total), 0), 1) }
}

/// Why a download failed, in words people can read (C#'s IOException from ModelStore).
public struct DownloadError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Speech models on this Mac (the Android and Windows apps' ModelStore). Downloads go to a primary folder; models are also
/// found, read only, in shared folders, where Voice Assistant keeps the same models, so they aren't downloaded twice. A
/// model is one or more files; each download resumes after a dropped connection and is checked against its pinned
/// SHA-256 before it gets its final name (a mismatch deletes it).
///
/// Verified files are remembered in `indexFileName` in the primary folder (path, size, last-write time and hash), so
/// making sure a model is intact on every start doesn't read 660 MB again: a file is hashed once, and again only if its
/// size or time changes. One small index rather than a file next to each model, because the shared folders belong to
/// other apps and the index is only a cache: if it's lost, files are simply hashed once more.
public final class ModelStore: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

    /// The verified-files index in the primary folder (kept by `removeLeftovers`), in the Windows app's format.
    public static let indexFileName = "verified.tsv"

    private static let maxAttempts = 5
    private static let spaceMargin: Int64 = 50_000_000
    fileprivate static let reportEvery: Int64 = 512 * 1024

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "ThumbFree"]
        return URLSession(configuration: configuration)
    }()

    public let primaryFolder: String
    public let sharedFolders: [String]

    /// Wait before retrying a failed file: attempt n waits n times this (2, 4, 6, 8 s, as on Android).
    public let retryDelay: TimeInterval

    /// A connection that sends nothing for this long counts as dropped (and is retried).
    public let readTimeout: TimeInterval

    /// Free bytes where downloads go, or nil if unknown. Tests replace it.
    var freeSpace: @Sendable () -> Int64?

    private let session: URLSession
    private let lock = NSLock()
    private var index: [String: Verified]?
    private var fileGates: [String: AsyncGate] = [:]
    private var downloads: [Download] = []

    /// - Parameters:
    ///   - primaryFolder: Where downloads go (the app passes `ModelStore.defaultFolder`).
    ///   - sharedFolders: Other apps' model folders, read only (the app passes `ModelStore.defaultSharedFolders`).
    ///   - session: For tests; by default one shared session that caches nothing.
    public init(
        primaryFolder: String,
        sharedFolders: [String] = [],
        session: URLSession? = nil,
        retryDelay: TimeInterval = 2,
        readTimeout: TimeInterval = 30
    ) {
        precondition(!primaryFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "No models folder")
        let primary = Files.fullPath(primaryFolder)
        var shared: [String] = []
        for folder in sharedFolders.map(Files.fullPath)
        where !ModelStore.samePath(folder, primary) && !shared.contains(where: { ModelStore.samePath($0, folder) }) {
            shared.append(folder)
        }

        self.primaryFolder = primary
        self.sharedFolders = shared
        self.session = session ?? ModelStore.defaultSession
        self.retryDelay = retryDelay
        self.readTimeout = readTimeout
        freeSpace = { ModelStore.volumeFreeSpace(primary) }
    }

    /// ~/Library/Application Support/ThumbFree/models, where the app keeps its models.
    public static var defaultFolder: String { applicationSupport("ThumbFree/models") }

    /// Voice Assistant's (Jarvis for Mac's) models folder. On Windows, ThumbFree also reads Voice Dictation's and Voice
    /// Assistant's folders; the Mac has no Voice Dictation.
    public static var defaultSharedFolders: [String] { [applicationSupport("VoiceAssistant/models")] }

    private var folders: [String] { [primaryFolder] + sharedFolders }

    /// Where `file` is: the primary folder first, then the shared folders; nil if it isn't on this Mac.
    public func pathOf(_ file: ModelFile) -> String? {
        folders.lazy.map { Self.pathIn($0, file) }.first { Self.isComplete($0, file) }
    }

    public func isInstalled(_ file: ModelFile) -> Bool { pathOf(file) != nil }

    /// Every file of `spec` is in one folder at its full size. Cheap (nothing is read): a downloaded file only gets its
    /// final name once its hash matched. `download(_:progress:)` checks the hashes of files it didn't verify itself.
    public func isInstalled(_ spec: ModelSpec) -> Bool { folderHolding(spec) != nil }

    /// The folder a recognizer loads `spec` from: for a multi-file model, its own folder (".../models/parakeet-tdt-110m").
    /// If the model isn't installed, where a download puts it.
    public func directoryOf(_ spec: ModelSpec) -> String {
        Files.parent(Self.pathIn(folderHolding(spec) ?? primaryFolder, spec.files[0]))
    }

    /// Bytes of `spec` already on this Mac, finished or partial (a download resumes from there).
    public func downloaded(_ spec: ModelSpec) -> Int64 {
        spec.files.reduce(0) { $0 + (isInstalled($1) ? $1.bytes : partLength($1)) }
    }

    /// Downloads `spec`'s missing files into the primary folder, one after another. Also the way to make sure an installed
    /// model is intact before loading it: files already verified are skipped without being read again. Checks the free
    /// space first, resumes partial downloads ("<file>.part", kept after a cancel or a dropped connection), tries each file
    /// up to 5 times (2, 4, 6, 8 s apart), and verifies its SHA-256 before giving it its final name. Throws
    /// `DownloadError` with a message people can read, or `CancellationError` when the task is cancelled or `delete` stops
    /// the download.
    public func download(_ spec: ModelSpec, progress: ProgressHandler? = nil) async throws {
        try await downloadFiles(spec.id, spec.files, progress)
    }

    /// One file, the same way: `ModelCatalog.vad` (Silero, used with Whisper and Parakeet) is installed with this.
    public func download(_ file: ModelFile, progress: ProgressHandler? = nil) async throws {
        try await downloadFiles(file.path, [file], progress)
    }

    /// Deletes `spec`'s files and partial downloads from the primary folder, stopping its download first. Copies in shared
    /// folders belong to other apps and stay (so the model may still be installed).
    public func delete(_ spec: ModelSpec) {
        lock.lock()
        let running = downloads.filter { $0.key == spec.id }
        lock.unlock()
        for download in running {
            download.cancel()

            // A cancelled download closes its file within milliseconds; it must be closed before it can be deleted.
            download.waitUntilStopped(timeout: 5)
        }

        let paths = spec.files.map { Self.pathIn(primaryFolder, $0) }.filter { !isShared($0) }
        for path in paths {
            Self.deleteFile(path)
            Self.deleteFile(path + ".part")
        }

        forget(paths)
        let folder = Files.parent(Self.pathIn(primaryFolder, spec.files[0]))
        if !Self.samePath(folder, primaryFolder) && !isShared(folder) {
            Self.deleteIfEmpty(folder)
        }
    }

    /// Deletes what this version doesn't use from the primary folder: files that aren't a current model file (or its
    /// partial download), such as models older versions used, then empty folders. Shared folders belong to other apps and
    /// are never touched, even one inside the primary folder.
    public func removeLeftovers() {
        guard Files.isDirectory(primaryFolder), let entries = FileManager.default.enumerator(atPath: primaryFolder) else {
            return
        }

        let known = ModelCatalog.knownPaths.flatMap { [$0, $0 + ".part"] } + [Self.indexFileName]
        let keep = Set(known.map { $0.lowercased() })
        var files: [String] = []
        var folders: [String] = []
        while let relative = entries.nextObject() as? String {
            let type = entries.fileAttributes?[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                entries.skipDescendants()
            } else if type == .typeDirectory {
                folders.append(relative)
            } else {
                files.append(relative)
            }
        }

        var removed: [String] = []
        for relative in files {
            let path = Files.combine(primaryFolder, relative)
            if !isShared(path) && !keep.contains(relative.lowercased()) && Self.deleteFile(path) {
                removed.append(path)
            }
        }

        let emptied = folders.map { Files.combine(primaryFolder, $0) }.filter { !isShared($0) }
        for folder in emptied.sorted(by: { $0.count > $1.count }) {
            Self.deleteIfEmpty(folder)
        }

        forget(removed)
    }

    private static func applicationSupport(_ relative: String) -> String {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
        return Files.combine(folder ?? Files.combine(NSHomeDirectory(), "Library/Application Support"), relative)
    }

    private static func pathIn(_ folder: String, _ file: ModelFile) -> String { Files.combine(folder, file.path) }

    private static func isComplete(_ path: String, _ file: ModelFile) -> Bool { Files.info(path)?.bytes == file.bytes }

    /// `Path.TrimEndingDirectorySeparator` on both, then compared ignoring case (Mac volumes usually ignore case).
    private static func samePath(_ a: String, _ b: String) -> Bool {
        trimmingSeparator(a).lowercased() == trimmingSeparator(b).lowercased()
    }

    private static func trimmingSeparator(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `File.Delete`: true if the file is gone (or was never there).
    @discardableResult
    fileprivate static func deleteFile(_ path: String) -> Bool { unlink(path) == 0 || errno == ENOENT }

    /// Deletes `folder` if it's empty; one in use goes next time.
    private static func deleteIfEmpty(_ folder: String) { _ = rmdir(folder) }

    /// The SHA-256 of a file, in lowercase hex. Stops with `CancellationError` when the task is cancelled.
    private static func sha256(of path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw DownloadError("Couldn't read \(path).") }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }

        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The text after "Couldn't download <file>: ".
    private static func describe(_ error: Error) -> String {
        (error as? DownloadError)?.message ?? error.localizedDescription
    }

    private static func volumeFreeSpace(_ folder: String) -> Int64? {
        // The folder may not exist yet: ask about the nearest one that does.
        var url = URL(fileURLWithPath: folder)
        while !FileManager.default.fileExists(atPath: url.path) && url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }

        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }

        return values.volumeAvailableCapacity.map { Int64($0) }
    }

    private func partLength(_ file: ModelFile) -> Int64 {
        Files.info(Self.pathIn(primaryFolder, file) + ".part")?.bytes ?? 0
    }

    private func folderHolding(_ spec: ModelSpec) -> String? {
        folders.first { folder in spec.files.allSatisfy { Self.isComplete(Self.pathIn(folder, $0), $0) } }
    }

    /// Whether `path` is a shared folder or inside one.
    private func isShared(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return sharedFolders.contains { folder in
            Self.samePath(path, folder) || lowercased.hasPrefix(Self.trimmingSeparator(folder).lowercased() + "/")
        }
    }

    private func gate(for file: ModelFile) -> AsyncGate {
        lock.lock()
        defer { lock.unlock() }
        let key = file.path.lowercased()
        if let gate = fileGates[key] {
            return gate
        }

        let gate = AsyncGate()
        fileGates[key] = gate
        return gate
    }

    /// Runs the download in its own task, so `delete` can stop it as well as the caller.
    private func downloadFiles(_ key: String, _ files: [ModelFile], _ progress: ProgressHandler?) async throws {
        let download = Download(key)
        register(download)
        defer {
            unregister(download)
            download.stopped()
        }

        let work = Task { try await self.downloadAll(files, progress) }
        download.start(work)
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func register(_ download: Download) {
        lock.lock()
        downloads.append(download)
        lock.unlock()
    }

    private func unregister(_ download: Download) {
        lock.lock()
        downloads.removeAll { $0 === download }
        lock.unlock()
    }

    private func downloadAll(_ files: [ModelFile], _ progress: ProgressHandler?) async throws {
        let needed = files.filter { !isInstalled($0) }.reduce(Int64(0)) { $0 + $1.bytes - partLength($1) }
        if needed > 0, let free = freeSpace(), free < needed + Self.spaceMargin {
            let neededMB = (needed + Self.spaceMargin) / 1_000_000
            throw DownloadError("Not enough free space: \(neededMB) MB needed, \(free / 1_000_000) MB free.")
        }

        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var settled: Int64 = 0
        for (i, file) in files.enumerated() {
            let later = files[(i + 1)...].reduce(Int64(0)) { $0 + (isInstalled($1) ? $1.bytes : partLength($1)) }
            let others = settled + later
            try await ensureFile(file) { done in progress?(DownloadProgress(done: others + done, total: total)) }
            settled += file.bytes
        }

        progress?(DownloadProgress(done: total, total: total))
    }

    /// Makes sure `file` is on this Mac and intact, downloading it if needed.
    private func ensureFile(_ file: ModelFile, _ onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let fileGate = gate(for: file)
        try await fileGate.acquire()
        defer { fileGate.release() }
        for folder in folders {
            let existing = Self.pathIn(folder, file)
            if !Self.isComplete(existing, file) {
                continue
            }

            if try isIntact(existing, file) {
                onBytes(file.bytes)
                return
            }

            if Self.samePath(folder, primaryFolder) && !isShared(existing) {
                // Damaged on disk: download it again.
                Self.deleteFile(existing)
                forget([existing])
            }
        }

        guard URL(string: file.url) != nil else { throw DownloadError("Couldn't download \(file.name): bad address.") }
        let target = Self.pathIn(primaryFolder, file)
        let part = target + ".part"
        var attempt = 1
        while true {
            do {
                try await fetch(file, part, onBytes)
                break
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }

                if attempt >= Self.maxAttempts {
                    throw DownloadError("Couldn't download \(file.name): \(Self.describe(error))")
                }

                try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
                attempt += 1
            }
        }

        if try Self.sha256(of: part) != file.sha256.lowercased() {
            Self.deleteFile(part)
            throw DownloadError("The download of \(file.name) was damaged, so it was deleted. Try again.")
        }

        if rename(part, target) != 0 {
            throw DownloadError("Couldn't save \(file.name): \(String(cString: strerror(errno)))")
        }

        remember(target, file)
    }

    /// One attempt: appends to `part` from where it ends (HTTP Range), or starts over if the server can't resume.
    private func fetch(_ file: ModelFile, _ part: String, _ onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let have = Files.info(part)?.bytes ?? 0
        if have >= file.bytes {
            return
        }

        // Every attempt: the leftover cleanup may have removed an empty folder.
        try FileManager.default.createDirectory(atPath: Files.parent(part), withIntermediateDirectories: true)
        guard let url = URL(string: file.url) else { throw DownloadError("Bad address.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: max(60, readTimeout * 2))
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if have > 0 {
            request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
        }

        let fetch = Fetch(file: file, part: part, have: have, readTimeout: readTimeout, onBytes: onBytes)
        try await fetch.run(session, request)
    }

    private func isIntact(_ path: String, _ file: ModelFile) throws -> Bool {
        if isRemembered(path, file) {
            return true
        }

        if try Self.sha256(of: path) != file.sha256.lowercased() {
            return false
        }

        remember(path, file)
        return true
    }

    private static func key(_ path: String) -> String { Files.fullPath(path).lowercased() }

    private func isRemembered(_ path: String, _ file: ModelFile) -> Bool {
        guard let info = Files.info(path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let verified = loadedIndex()[Self.key(path)] else { return false }
        return verified.bytes == info.bytes && verified.writeTicks == info.writeTicks
            && verified.sha256.lowercased() == file.sha256.lowercased()
    }

    private func remember(_ path: String, _ file: ModelFile) {
        guard let info = Files.info(path) else { return }
        lock.lock()
        defer { lock.unlock() }
        var index = loadedIndex()
        index[Self.key(path)] = Verified(
            sha256: file.sha256.lowercased(), bytes: info.bytes, writeTicks: info.writeTicks, path: Files.fullPath(path))
        self.index = index
        saveIndexLocked()
    }

    private func forget(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var index = loadedIndex()
        var changed = false
        for path in paths {
            if index.removeValue(forKey: Self.key(path)) != nil {
                changed = true
            }
        }

        if changed {
            self.index = index
            saveIndexLocked()
        }
    }

    private func loadedIndex() -> [String: Verified] {
        if let index {
            return index
        }

        var loaded: [String: Verified] = [:]
        let path = Files.combine(primaryFolder, Self.indexFileName)
        // No index yet (or unreadable): files are hashed once more.
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
                if cells.count == 4, let bytes = Self.digits(cells[1]), let ticks = Self.digits(cells[2]) {
                    loaded[String(cells[3]).lowercased()] = Verified(
                        sha256: String(cells[0]), bytes: bytes, writeTicks: ticks, path: String(cells[3]))
                }
            }
        }

        index = loaded
        return loaded
    }

    private func saveIndexLocked() {
        guard let index else { return }
        let path = Files.combine(primaryFolder, Self.indexFileName)
        let temp = path + ".tmp"
        let lines = index.values.map { "\($0.sha256)\t\($0.bytes)\t\($0.writeTicks)\t\($0.path)\n" }
        do {
            try FileManager.default.createDirectory(atPath: primaryFolder, withIntermediateDirectories: true)
            try Data(lines.joined().utf8).write(to: URL(fileURLWithPath: temp))
            if rename(temp, path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            // Only a cache (a read-only models folder, say): files are hashed again next time.
            Self.deleteFile(temp)
        }
    }

    /// `long.TryParse(text, NumberStyles.None, ...)`: digits only.
    private static func digits(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(text)
    }

    private struct Verified {
        let sha256: String
        let bytes: Int64
        let writeTicks: Int64
        let path: String
    }
}

/// A running download, so `ModelStore.delete` can stop it and wait until its file is closed.
private final class Download: @unchecked Sendable {
    let key: String
    private let lock = NSLock()
    private let running = DispatchGroup()
    private var work: Task<Void, Error>?
    private var cancelled = false

    init(_ key: String) {
        self.key = key
        running.enter()
    }

    func start(_ work: Task<Void, Error>) {
        lock.lock()
        self.work = work
        let cancel = cancelled
        lock.unlock()
        if cancel {
            work.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let work = self.work
        lock.unlock()
        work?.cancel()
    }

    func stopped() { running.leave() }

    func waitUntilStopped(timeout: TimeInterval) { _ = running.wait(timeout: .now() + timeout) }
}

/// One HTTP request for a model file: the bytes go into its partial download as they arrive. A URLSession task delegate.
private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: ModelFile
    private let part: String
    private let have: Int64
    private let readTimeout: TimeInterval
    private let onBytes: @Sendable (Int64) -> Void
    private let watch = DispatchQueue(label: "ThumbFree.ModelStore.stall")
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var output: FileHandle?
    private var lastActivity = DispatchTime.now()
    private var done: Int64 = 0
    private var reported: Int64 = 0
    private var started = false
    private var complete = false
    private var finished = false
    private var cancelled = false
    private var failure: Error?

    init(file: ModelFile, part: String, have: Int64, readTimeout: TimeInterval,
         onBytes: @escaping @Sendable (Int64) -> Void) {
        self.file = file
        self.part = part
        self.have = have
        self.readTimeout = readTimeout
        self.onBytes = onBytes
    }

    func run(_ session: URLSession, _ request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let task = session.dataTask(with: request)
                task.delegate = self
                self.task = task
                self.continuation = continuation
                lastActivity = .now()
                lock.unlock()
                watchForStall(after: readTimeout)
                task.resume()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var report: [Int64] = []
        lock.lock()
        if failure == nil && !complete && !cancelled {
            do {
                if !started {
                    let start = try startLocked(dataTask.response)
                    report.append(start)
                }

                lastActivity = .now()
                try output?.write(contentsOf: data)
                done += Int64(data.count)
                if done - reported >= ModelStore.reportEvery {
                    reported = done
                    report.append(done)
                }

                if done >= file.bytes {
                    // All of it: stop reading here, as C# does.
                    complete = true
                    dataTask.cancel()
                }
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        lock.unlock()
        report.forEach(onBytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var report: [Int64] = []
        lock.lock()
        finished = true
        if failure == nil && !complete && !cancelled && !started && error == nil {
            // An answer without a body: a server error, say.
            do {
                let start = try startLocked(task.response)
                report.append(start)
            } catch {
                failure = error
            }
        }

        try? output?.close()
        output = nil
        let outcome: Result<Void, Error>
        if cancelled {
            outcome = .failure(CancellationError())
        } else if let failure {
            outcome = .failure(failure)
        } else if complete {
            report.append(done)
            outcome = .success(())
        } else if let error {
            let stalled = (error as? URLError)?.code == .timedOut
            outcome = .failure(DownloadError(stalled ? "The connection stalled." : error.localizedDescription))
        } else {
            report.append(done)
            outcome = done < file.bytes ? .failure(DownloadError("The connection dropped.")) : .success(())
        }

        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        report.forEach(onBytes)
        continuation?.resume(with: outcome)
    }

    /// Checks the answer and opens the partial download (appending to it for 206); returns the bytes it then has.
    private func startLocked(_ response: URLResponse?) throws -> Int64 {
        started = true
        guard let response = response as? HTTPURLResponse else { throw DownloadError("The server didn't answer.") }
        if response.statusCode == 416 {
            ModelStore.deleteFile(part)
            throw DownloadError("The server couldn't resume the download.")
        }

        if response.statusCode != 200 && response.statusCode != 206 {
            throw DownloadError("The server answered \(response.statusCode).")
        }

        let append = response.statusCode == 206
        if append && Self.rangeStart(response) != have {
            ModelStore.deleteFile(part)
            throw DownloadError("The server resumed at the wrong place.")
        }

        let descriptor = open(part, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o644)
        if descriptor < 0 {
            throw DownloadError("Couldn't write \(file.name): \(String(cString: strerror(errno)))")
        }

        output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        done = append ? have : 0
        reported = done
        return done
    }

    /// Cancels the request once nothing has arrived for `readTimeout`, checking again when the time is up.
    private func watchForStall(after delay: TimeInterval) {
        watch.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.finished && !self.cancelled && self.failure == nil && !self.complete else {
                self.lock.unlock()
                return
            }

            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastActivity.uptimeNanoseconds) / 1e9
            if idle < self.readTimeout {
                self.lock.unlock()
                self.watchForStall(after: self.readTimeout - idle)
                return
            }

            self.failure = DownloadError("The connection stalled.")
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    /// Where a 206 answer starts ("Content-Range: bytes 150000-299999/300000" → 150000).
    private static func rangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces),
              range.lowercased().hasPrefix("bytes ")
        else { return nil }

        let from = range.dropFirst(6)
        guard let dash = from.firstIndex(of: "-") else { return nil }
        return Int64(from[..<dash].trimmingCharacters(in: .whitespaces))
    }
}
