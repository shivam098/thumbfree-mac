import CryptoKit
import Foundation
import ThumbFreeCore
import XCTest
@testable import ThumbFreeSpeech

/// Downloads against a local server: resume, retries, hash checks, shared folders and cleanup.
final class ModelStoreTests: XCTestCase {
    private static let http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private var server: TestServer!
    private var scratch: Scratch!

    override func setUpWithError() throws {
        server = try TestServer()
        scratch = try Scratch()
    }

    override func tearDown() {
        server?.close()
        scratch?.remove()
    }

    func testDownloadsFilesOneAfterAnotherAndNamesThemOnceVerified() async throws {
        let encoder = randomBytes(1)
        let tokens = randomBytes(2, 1_000)
        let spec = makeSpec(serve("model-x/encoder.onnx", encoder), serve("model-x/tokens.txt", tokens))
        let store = makeStore()
        let reports = Locked<[DownloadProgress]>([])

        XCTAssertFalse(store.isInstalled(spec))
        try await store.download(spec) { progress in reports.update { $0.append(progress) } }

        XCTAssertTrue(store.isInstalled(spec))
        XCTAssertEqual(store.directoryOf(spec), scratch.file("models/model-x"))
        XCTAssertEqual(store.pathOf(spec.files[1]), scratch.file("models/model-x/tokens.txt"))
        XCTAssertEqual(try Data(contentsOf: url("models/model-x/encoder.onnx")), encoder)
        XCTAssertEqual(try Data(contentsOf: url("models/model-x/tokens.txt")), tokens)
        XCTAssertEqual(filesUnder(scratch.path).filter { $0.hasSuffix(".part") }, [])
        XCTAssertEqual(server.requests, ["model-x_encoder.onnx -", "model-x_tokens.txt -"])
        XCTAssertEqual(reports.value.last, DownloadProgress(done: spec.bytes, total: spec.bytes))
        XCTAssertTrue(reports.value.allSatisfy { (0...spec.bytes).contains($0.done) }, "\(reports.value)")
    }

    func testInstallsASingleFileSuchAsTheVoiceActivityModel() async throws {
        let vad = serve("ggml-silero-test.bin", randomBytes(3, 5_000))
        let store = makeStore()

        try await store.download(vad)

        XCTAssertEqual(store.pathOf(vad), scratch.file("models/ggml-silero-test.bin"))
        XCTAssertTrue(store.isInstalled(vad))
    }

    func testResumesAfterADroppedConnection() async throws {
        let bytes = randomBytes(4)
        let spec = makeSpec(serve("big.bin", bytes))
        server.behave = { $0 == 1 ? .dropHalfway : .normal }

        try await makeStore().download(spec)

        XCTAssertEqual(try Data(contentsOf: url("models/big.bin")), bytes)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(request(0), "big.bin -")
        XCTAssertTrue((1...Int64(bytes.count - 1)).contains(resumedAt(request(1))), request(1))
    }

    func testAStalledConnectionIsRetriedFromWhereItStopped() async throws {
        let bytes = randomBytes(5)
        let spec = makeSpec(serve("big.bin", bytes))
        server.behave = { $0 == 1 ? .stallHalfway : .normal }

        try await makeStore(readTimeout: 0.3).download(spec)

        XCTAssertEqual(try Data(contentsOf: url("models/big.bin")), bytes)
        XCTAssertTrue((1...Int64(bytes.count - 1)).contains(resumedAt(request(1))), request(1))
    }

    func testStartsOverWhenTheServerCannotResume() async throws {
        let bytes = randomBytes(6)
        let spec = makeSpec(serve("big.bin", bytes))
        server.behave = { $0 == 1 ? .dropHalfway : .ignoreRange }

        try await makeStore().download(spec)

        XCTAssertEqual(try Data(contentsOf: url("models/big.bin")), bytes)
        XCTAssertTrue(request(1).hasPrefix("big.bin bytes="), request(1))
    }

    func testCancellingKeepsThePartialDownloadForNextTime() async throws {
        let bytes = randomBytes(7)
        let spec = makeSpec(serve("big.bin", bytes))
        server.behave = { $0 == 1 ? .stallHalfway : .normal }
        let part = scratch.file("models/big.bin.part")
        let store = makeStore()
        let download = Task { try await store.download(spec) }
        try await waitUntil { (Files.info(part)?.bytes ?? 0) > 0 }

        download.cancel()
        let result = await download.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let kept = Files.info(part)?.bytes ?? 0
        try await makeStore().download(spec)

        XCTAssertTrue((1...Int64(bytes.count - 1)).contains(kept), "\(kept)")
        XCTAssertEqual(request(1), "big.bin bytes=\(kept)-")
        XCTAssertEqual(try Data(contentsOf: url("models/big.bin")), bytes)
    }

    func testADamagedDownloadIsDeletedWithAClearMessage() async throws {
        let spec = makeSpec(serve("model.bin", randomBytes(8), pinned: randomBytes(9)))

        do {
            try await makeStore().download(spec)
            XCTFail("The download didn't fail")
        } catch let error as DownloadError {
            XCTAssertTrue(error.message.contains("model.bin was damaged"), error.message)
        }

        XCTAssertEqual(filesUnder(scratch.path), [])
    }

    func testRetriesFailedRequestsThenGivesUpAfterFiveTries() async throws {
        let good = makeSpec(serve("good.bin", randomBytes(10)))
        server.behave = { $0 <= 2 ? .serverError : .normal }
        try await makeStore().download(good)
        XCTAssertEqual(server.requests.count, 3)

        let bad = makeSpec(serve("bad.bin", randomBytes(11)))
        server.behave = { _ in .serverError }
        do {
            try await makeStore().download(bad)
            XCTFail("The download didn't fail")
        } catch let error as DownloadError {
            XCTAssertEqual(error.message, "Couldn't download bad.bin: The server answered 500.")
        }

        XCTAssertEqual(server.requests.filter { $0.hasPrefix("bad.bin") }.count, 5)
    }

    func testChecksTheFreeSpaceBeforeStarting() async throws {
        let spec = makeSpec(serve("big.bin", randomBytes(12)))
        let store = ModelStore(primaryFolder: scratch.file("models"), session: Self.http)
        store.freeSpace = { 1_000 }

        do {
            try await store.download(spec)
            XCTFail("The download didn't fail")
        } catch let error as DownloadError {
            XCTAssertTrue(error.message.hasPrefix("Not enough free space"), error.message)
        }

        XCTAssertEqual(server.requests, [])
    }

    func testSkipsFilesAlreadyPresentAndVerifiedEvenAfterARestart() async throws {
        let spec = makeSpec(
            serve("model-x/encoder.onnx", randomBytes(13)), serve("model-x/tokens.txt", randomBytes(14, 900)))
        try await makeStore().download(spec)

        try await makeStore().download(spec)
        try FileManager.default.removeItem(atPath: scratch.file("models/" + ModelStore.indexFileName))
        try await makeStore().download(spec)

        XCTAssertEqual(server.requests.count, 2)
    }

    func testRemembersVerifiedFilesBySizeAndTimeInsteadOfHashingThemAgain() async throws {
        let bytes = randomBytes(15)
        let spec = makeSpec(serve("model.bin", bytes))
        try await makeStore().download(spec)
        let path = scratch.file("models/model.bin")

        // Same size and time: trusted from the index, not read (that's what keeps a 660 MB check instant).
        let time = try modificationTime(path)
        var damaged = try Data(contentsOf: URL(fileURLWithPath: path))
        damaged[damaged.count - 1] ^= 0xFF
        try damaged.write(to: URL(fileURLWithPath: path))
        try setModificationTime(path, time)
        try await makeStore().download(spec)
        XCTAssertEqual(server.requests.count, 1)

        // A new time: hashed again, found damaged, downloaded again.
        try setModificationTime(path, timespec(tv_sec: time.tv_sec + 60, tv_nsec: time.tv_nsec))
        try await makeStore().download(spec)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    func testUsesModelsFromSharedFoldersWithoutChangingThem() async throws {
        let bytes = randomBytes(16)
        let spec = makeSpec(serve("ggml-shared.bin", bytes))

        // One shared folder inside the models folder, where a cleanup could reach it, and one next to it.
        let inside = try sharedFolder("models/voice-assistant", ("ggml-shared.bin", bytes))
        let alongside = try sharedFolder("voice-dictation", ("ggml-shared.bin", bytes))
        let before = try snapshot(inside, alongside)
        let store = makeStore([inside, alongside])

        XCTAssertTrue(store.isInstalled(spec))
        XCTAssertEqual(store.pathOf(spec.files[0]), (inside as NSString).appendingPathComponent("ggml-shared.bin"))
        XCTAssertEqual(store.directoryOf(spec), inside)
        try await store.download(spec)
        store.removeLeftovers(keeping: ModelCatalog.knownPaths)
        store.delete(spec)

        XCTAssertEqual(server.requests, [])
        XCTAssertTrue(store.isInstalled(spec))
        XCTAssertEqual(try snapshot(inside, alongside), before)
    }

    func testADamagedSharedCopyIsLeftAloneAndTheModelDownloaded() async throws {
        let bytes = randomBytes(17)
        let spec = makeSpec(serve("ggml-shared.bin", bytes))
        let shared = try sharedFolder("voice-assistant", ("ggml-shared.bin", randomBytes(18)))
        let before = try snapshot(shared)
        let store = makeStore([shared])

        try await store.download(spec)

        XCTAssertEqual(store.pathOf(spec.files[0]), scratch.file("models/ggml-shared.bin"))
        XCTAssertEqual(try snapshot(shared), before)
    }

    func testDeleteStopsTheDownloadAndRemovesTheModel() async throws {
        let bytes = randomBytes(19)
        let done = makeSpec(serve("model-x/tokens.txt", randomBytes(20, 500)))
        let store = makeStore()
        try await store.download(done)
        store.delete(done)
        XCTAssertFalse(store.isInstalled(done))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/model-x")))

        let running = makeSpec(serve("model-y/encoder.onnx", bytes))
        server.behave = { _ in .stallHalfway }
        let download = Task { try await store.download(running) }
        let part = scratch.file("models/model-y/encoder.onnx.part")
        try await waitUntil { FileManager.default.fileExists(atPath: part) }
        store.delete(running)

        let result = await download.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/model-y")))
    }

    func testRemoveLeftoversKeepsCurrentModelsAndNeverTouchesSharedFolders() throws {
        let keep = [
            ModelCatalog.englishFast.files[3].path,
            ModelCatalog.englishFast.files[0].path + ".part",
            ModelCatalog.vad.path,
            ModelCatalog.hinglish.files[0].path,
            ModelStore.indexFileName,
        ]
        let leftovers = [
            "ggml-small.en-q8_0.bin", "ggml-small.en-q8_0.bin.partial", "parakeet-tdt-110m/old.onnx",
            "old-model/encoder.onnx",
        ]
        for path in keep + leftovers {
            let file = scratch.file("models/" + path)
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        }

        try FileManager.default.createDirectory(
            atPath: scratch.file("models/empty/inner"), withIntermediateDirectories: true)
        let inside = try sharedFolder("models/voice-assistant")
        let alongside = try sharedFolder("voice-dictation")
        let before = try snapshot(inside, alongside)

        makeStore([inside, alongside]).removeLeftovers(keeping: ModelCatalog.knownPaths)

        for path in keep {
            XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.file("models/" + path)), path)
        }

        for path in leftovers {
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/" + path)), path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/old-model")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/empty")))
        XCTAssertEqual(try snapshot(inside, alongside), before)
    }

    func testRemoveLeftoversKeepsTheCatalogItIsGivenSoAnotherAppKeepsItsModels() throws {
        // Jarvis's folder: its own Whisper models, two of ThumbFree's models it uses too, and files in neither list.
        let jarvis = ["ggml-small.en-q8_0.bin", "ggml-base.en-q8_0.bin", "ggml-base.en.bin"]
        let thumbFree = [ModelCatalog.vad.path, ModelCatalog.hinglish.files[0].path]
        let kept = jarvis + thumbFree + ["ggml-base.en.bin.part", ModelStore.indexFileName]
        let neither = [
            "ggml-tiny.en.bin", "ggml-small.en-q8_0.bin.partial", ModelCatalog.englishLive.files[0].path,
            "old-model/encoder.onnx",
        ]
        try writeFiles(kept + neither, in: "models")
        let inside = try sharedFolder("models/thumbfree")
        let alongside = try sharedFolder("thumbfree")
        let before = try snapshot(inside, alongside)

        makeStore([inside, alongside]).removeLeftovers(keeping: jarvis + thumbFree)

        for path in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.file("models/" + path)), path)
        }

        for path in neither {
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/" + path)), path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/kroko-en-live")))
        XCTAssertEqual(try snapshot(inside, alongside), before)

        // ThumbFree's catalog, as before: Jarvis's Whisper models aren't in it.
        makeStore([inside, alongside]).removeLeftovers(keeping: ModelCatalog.knownPaths)

        for path in jarvis {
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.file("models/" + path)), path)
        }

        for path in thumbFree {
            XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.file("models/" + path)), path)
        }

        XCTAssertEqual(try snapshot(inside, alongside), before)
    }

    func testDownloadsSayWhichAppTheyComeFrom() async throws {
        let spec = makeSpec(serve("model.bin", randomBytes(21, 1_000)))
        let jarvis = ModelStore(primaryFolder: scratch.file("jarvis"), userAgent: "Jarvis", session: Self.http)

        try await makeStore().download(spec)
        try await jarvis.download(spec)

        XCTAssertEqual(server.userAgents, ["ThumbFree", "Jarvis"])
    }

    /// Deterministic bytes for a seed (SplitMix64). The C# tests use `new Random(seed).NextBytes`, which this doesn't
    /// reproduce: the tests only need the same bytes on every run, not the C# bytes.
    private func randomBytes(_ seed: Int, _ length: Int = 300_000) -> Data {
        var data = Data(capacity: length)
        var state = UInt64(truncatingIfNeeded: seed)
        while data.count < length {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let remaining = length - data.count
            withUnsafeBytes(of: z.littleEndian) { data.append(contentsOf: $0.prefix(remaining)) }
        }

        return data
    }

    private func makeSpec(_ files: ModelFile...) -> ModelSpec {
        ModelSpec(id: "test-model", label: "Test model", language: .english, engine: .parakeet, files: files)
    }

    private func makeStore(_ shared: [String] = [], readTimeout: TimeInterval = 10) -> ModelStore {
        ModelStore(
            primaryFolder: scratch.file("models"), sharedFolders: shared, session: Self.http, retryDelay: 0.01,
            readTimeout: readTimeout)
    }

    private func serve(_ path: String, _ bytes: Data, pinned: Data? = nil) -> ModelFile {
        let url = server.add(path.replacingOccurrences(of: "/", with: "_"), bytes)
        let expected = pinned ?? bytes
        return ModelFile(path, url, sha256(expected), Int64(expected.count))
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Request number `index` (from 0), or "" if there isn't one.
    private func request(_ index: Int) -> String {
        let all = server.requests
        return index < all.count ? all[index] : ""
    }

    /// Where a request resumed: "big.bin bytes=150000-" → 150000.
    private func resumedAt(_ request: String) -> Int64 {
        guard let range = request.range(of: "bytes=[0-9]+-$", options: .regularExpression) else { return -1 }
        return Int64(request[range].dropFirst(6).dropLast()) ?? -1
    }

    private func url(_ relative: String) -> URL { URL(fileURLWithPath: scratch.file(relative)) }

    /// A one-byte file at each of `paths` in `folder`, with the folders it's in.
    private func writeFiles(_ paths: [String], in folder: String) throws {
        for path in paths {
            let file = scratch.file(folder + "/" + path)
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        }
    }

    /// Every file below `folder`, relative to it.
    private func filesUnder(_ folder: String) -> [String] {
        var files: [String] = []
        let entries = FileManager.default.enumerator(atPath: folder)
        while let relative = entries?.nextObject() as? String {
            if Files.isFile((folder as NSString).appendingPathComponent(relative)) {
                files.append(relative)
            }
        }

        return files
    }

    /// Every file and folder under `folders`, with its content hash and last-write time.
    private func snapshot(_ folders: String...) throws -> [String] {
        var lines: [String] = []
        for folder in folders {
            var paths = [folder]
            let entries = FileManager.default.enumerator(atPath: folder)
            while let relative = entries?.nextObject() as? String {
                paths.append((folder as NSString).appendingPathComponent(relative))
            }

            for path in paths {
                let time = try modificationTime(path)
                if Files.isFile(path) {
                    let content = try Data(contentsOf: URL(fileURLWithPath: path))
                    lines.append("\(path) \(sha256(content)) \(time.tv_sec).\(time.tv_nsec)")
                } else {
                    lines.append("\(path) folder \(time.tv_sec).\(time.tv_nsec)")
                }
            }
        }

        return lines.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Another app's models folder: `files`, an old model and a partial download ThumbFree doesn't use, an empty
    /// folder, all dated a year ago (so any write shows).
    private func sharedFolder(_ relative: String, _ files: (String, Data)...) throws -> String {
        let folder = scratch.file(relative)
        let old = (folder as NSString).appendingPathComponent("old")
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        let unused = [
            ("ggml-small.en-q8_0.bin", randomBytes(98, 1_000)),
            ("ggml-small.en-q8_0.bin.partial", randomBytes(99, 500)),
        ]
        for (name, bytes) in files + unused {
            try bytes.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)))
        }

        let yearAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder) + [""] {
            let path = name.isEmpty ? folder : (folder as NSString).appendingPathComponent(name)
            try FileManager.default.setAttributes([.modificationDate: yearAgo], ofItemAtPath: path)
        }

        return folder
    }

    private func modificationTime(_ path: String) throws -> timespec {
        var status = stat()
        guard stat(path, &status) == 0 else { throw POSIXError(.ENOENT) }
        return status.st_mtimespec
    }

    /// Sets a file's last-write time to the nanosecond (the index compares it exactly).
    private func setModificationTime(_ path: String, _ time: timespec) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
        defer { Darwin.close(descriptor) }
        var times = [time, time]
        guard futimens(descriptor, &times) == 0 else { throw POSIXError(.EPERM) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(condition(), "timed out waiting")
    }
}
