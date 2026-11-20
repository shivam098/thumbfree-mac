import XCTest
import ThumbFreeCore
import ThumbFreeSpeech
@testable import ThumbFreeApp

/// thumbfree-windows tests/ThumbFree.App.Tests/StoreTests.cs: HistoryStoreTests.
final class HistoryStoreTests: XCTestCase {
    private var folder: TempFolder!
    private var now = testStart
    private var keep = true
    private var file: String { folder.file("history.txt") }

    override func setUp() {
        folder = TempFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testKeepsDictationsNewestFirstInTheSharedFormat() throws {
        let store = newStore()
        store.add("Hey Tim,\n\nWould love to connect.", app: "OUTLOOK", passwordField: false)
        now += 120
        store.add("Buy milk\tand eggs", app: "notepad", passwordField: false)
        XCTAssertTrue(store.flush(timeout: 5))

        let entries = store.entries()
        XCTAssertEqual(entries.map(\.text), ["Buy milk\tand eggs", "Hey Tim,\n\nWould love to connect."])
        XCTAssertEqual(entries[0].app, "notepad")
        let lines = TestFiles.text(file).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.compactMap(History.decode), entries)
        XCTAssertTrue(lines[1].contains(#"Hey Tim,\n\nWould"#))

        // A new session reads what the last one wrote.
        XCTAssertEqual(newStore().entries(), entries)

        // The Mac keeps it out of Time Machine backups (PLAN 3.11), and out of Spotlight with its folder (AppPaths),
        // where Windows keeps it out of the search index.
        let values = try URL(fileURLWithPath: file).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testNeverKeepsPasswordFieldsBlankTextOrAnythingWhileOff() {
        let store = newStore()
        store.add("hunter2", app: "Google Chrome", passwordField: true)
        store.add("   ", app: "Google Chrome", passwordField: false)
        keep = false
        store.add("Kept while off?", app: "Google Chrome", passwordField: false)
        store.flush(timeout: 5)

        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(TestFiles.exists(file))
    }

    func testDropsEntriesOlderThan30DaysAndKeepsTheNewest500() {
        let start = Int64(testStart.timeIntervalSince1970 * 1000)
        let old = (0..<5).map {
            HistoryEntry(time: start - History.maxAgeMs - 1000 - Int64($0), app: "app", text: "old \($0)")
        }
        let recent = (0..<510).map { HistoryEntry(time: start - Int64($0) * 1000, app: "app", text: "recent \($0)") }
        let lines = (old + recent).map(History.encode) + ["damaged line", "1\tonly two"]
        TestFiles.write(file, lines.map { $0 + "\n" }.joined())
        let store = newStore()

        let entries = store.entries()
        store.flush(timeout: 5)

        XCTAssertEqual(entries.count, History.maxEntries)
        XCTAssertEqual(entries[0].text, "recent 0")
        XCTAssertFalse(entries.contains { $0.text.hasPrefix("old") })
        XCTAssertEqual(TestFiles.text(file).components(separatedBy: "\n").count, History.maxEntries)
    }

    func testDeletesOneOrAll() {
        let store = newStore()
        var changes = 0
        store.observe { changes += 1 }
        for text in ["one", "two", "three"] {
            now += 1
            store.add(text, app: "app", passwordField: false)
        }

        store.delete(store.entries()[1])
        XCTAssertEqual(store.entries().map(\.text), ["three", "one"])

        store.clear()
        store.flush(timeout: 5)
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(TestFiles.exists(file))
        XCTAssertEqual(changes, 5)
    }

    func testAddsFromManyThreadsAreAllKept() {
        let store = HistoryStore(path: file, enabled: { true })
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            store.add("dictation \(i)", app: "app", passwordField: false)
        }

        store.flush(timeout: 5)

        XCTAssertEqual(store.entries().count, 200)
        XCTAssertEqual(HistoryStore(path: file, enabled: { true }).entries().count, 200)
    }

    func testSaysWhenInWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = india
        let cases = [
            (20, "just now"), (60, "1 minute ago"), (150, "2 minutes ago"), (3600, "1 hour ago"),
            (5 * 3600, "5 hours ago"), (26 * 3600, "yesterday"), (3 * 86400, "3 days ago"),
        ]
        for (secondsAgo, expected) in cases {
            let time = testStart - TimeInterval(secondsAgo)
            XCTAssertEqual(RelativeTime.describe(time, now: testStart, calendar: calendar), expected)
        }
    }

    func testCaptionsNameTheApp() {
        let time = Int64(testStart.timeIntervalSince1970 * 1000) - 120_000
        func caption(_ app: String) -> String {
            RelativeTime.caption(HistoryEntry(time: time, app: app, text: "x"), now: testStart)
        }

        XCTAssertEqual(caption("OUTLOOK"), "Outlook · 2 minutes ago")
        XCTAssertEqual(caption("slack"), "Slack · 2 minutes ago")
        XCTAssertEqual(caption("obscureapp"), "Obscureapp · 2 minutes ago")
        XCTAssertEqual(caption(""), "2 minutes ago")

        // The Mac records an app's name as macOS shows it.
        XCTAssertEqual(caption("Microsoft Outlook"), "Microsoft Outlook · 2 minutes ago")
    }

    /// history.txt as ThumbFree for Windows 0.8 writes it, with text that has to be escaped.
    func testAWindowsHistoryFileReadsTheSameAndIsWrittenTheSame() {
        let windows = [
            "1795091404000\tCode\t", #"a"b\\c\nd\te"#, "\u{1}f😀g\u{A0}hé\u{2028}i\u{AD}j<>&'+`\u{FEFF}k\u{E000}l",
            #"\r"#, "\n",
            "1795091403000\t\tno app\n",
            "1795091402000\texplorer\t", #"C:\\temp\\new\tfolder"#, " 😀\n",
            "1795091401000\tOUTLOOK\t", #"Hey Tim,\n\nWould love to connect.\r\nThanks"#,
        ].joined()
        TestFiles.write(file, windows)
        now = Date(timeIntervalSince1970: 1_795_091_405)
        let store = newStore()

        XCTAssertEqual(store.entries(), [
            HistoryEntry(time: 1_795_091_404_000, app: "Code", text: trickyText),
            HistoryEntry(time: 1_795_091_403_000, app: "", text: "no app"),
            HistoryEntry(time: 1_795_091_402_000, app: "explorer", text: "C:\\temp\\new\tfolder 😀"),
            HistoryEntry(time: 1_795_091_401_000, app: "OUTLOOK", text: "Hey Tim,\n\nWould love to connect.\r\nThanks"),
        ])

        store.delete(HistoryEntry(time: 0, app: "", text: "not there"))
        XCTAssertTrue(store.flush(timeout: 5))
        XCTAssertEqual(TestFiles.bytes(file), Array(windows.utf8))
    }

    private func newStore() -> HistoryStore {
        HistoryStore(path: file, enabled: { [unowned self] in self.keep }, clock: { [unowned self] in self.now })
    }
}

/// StoreTests.cs: SampleStoreTests. Apps are named by bundle identifier, where Windows has process names.
final class SampleStoreTests: XCTestCase {
    private static let outlook = TargetApp(name: "Microsoft Outlook", bundleIdentifier: "com.microsoft.Outlook")

    private var folder: TempFolder!
    private var now = testStart
    private var enabled = true

    override class func setUp() {
        super.setUp()
        useTestBrowsers()
    }

    override func setUp() {
        folder = TempFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testKeepsTheAudioAndANoteWhenSwitchedOn() throws {
        let store = newStore()
        let audio = (0..<16000).map { sin(Float($0) / 10) * 0.5 }

        XCTAssertTrue(
            store.save(
                audio, recognized: "hey tim would love to connect", typed: "Hey Tim, would love to connect.",
                model: ModelCatalog.englishLive, passwordField: false, app: Self.outlook))
        store.flush(timeout: 5)

        XCTAssertEqual(TestFiles.folders(store.folder), ["20261119-180000-000"])
        let sample = (store.folder as NSString).appendingPathComponent("20261119-180000-000")
        let wav = TestFiles.bytes(sample + "/audio.wav")
        XCTAssertEqual(wav.count, 44 + audio.count * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(Self.int(wav, at: 24, bytes: 4), 16000)
        XCTAssertEqual(Self.int(wav, at: 22, bytes: 2), 1)
        XCTAssertEqual(Self.int(wav, at: 34, bytes: 2), 16)
        let read = try WavFile.readPcm16Mono16k(sample + "/audio.wav")
        XCTAssertEqual(read.count, audio.count)
        XCTAssertTrue(zip(read, audio).allSatisfy { abs($0 - $1) < 1e-4 })

        let note = try TestFiles.json(sample + "/meta.json")
        XCTAssertEqual(
            note.keys.sorted(),
            ["app", "app_version", "language", "model", "platform", "seconds", "time", "transcript", "typed"])
        XCTAssertEqual(note["model"] as? String, "en-kroko-live")
        XCTAssertEqual(note["transcript"] as? String, "hey tim would love to connect")
        XCTAssertEqual(note["typed"] as? String, "Hey Tim, would love to connect.")
        XCTAssertEqual(note["app"] as? String, "Microsoft Outlook")
        XCTAssertEqual(note["app_version"] as? String, "0.8.0")
        XCTAssertEqual(note["seconds"] as? Double, 1.0)
        XCTAssertTrue((note["time"] as? String)?.hasPrefix("2026-11-19T18:00:00") == true)
        let metaBytes = Int64(TestFiles.bytes(sample + "/meta.json").count)
        XCTAssertEqual(store.summary(), SampleSummary(count: 1, bytes: Int64(wav.count) + metaBytes))

        // Written as Windows writes it (System.Text.Json, indented), with the Mac's own platform.
        XCTAssertEqual(TestFiles.text(sample + "/meta.json"), """
            {
              "model": "en-kroko-live",
              "language": "English",
              "seconds": 1,
              "transcript": "hey tim would love to connect",
              "typed": "Hey Tim, would love to connect.",
              "app": "Microsoft Outlook",
              "app_version": "0.8.0",
              "platform": "macos",
              "time": "2026-11-19T18:00:00.0000000+05:30"
            }
            """)
    }

    /// The length is written as Windows writes it: rounded to hundredths, half to even, without a fraction when
    /// there's none.
    func testANoteGivesTheLengthAsWindowsDoes() throws {
        let store = newStore()
        for samples in [37_600, 1, 160] {
            now += 1
            store.save(
                [Float](repeating: 0.1, count: samples), recognized: "a", typed: "A.", model: ModelCatalog.hinglish,
                passwordField: false, app: nil)
        }

        store.flush(timeout: 5)

        let notes = TestFiles.folders(store.folder).map { name in
            TestFiles.text((store.folder as NSString).appendingPathComponent(name + "/meta.json"))
        }
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes[0].contains("\"seconds\": 2.35,"), notes[0])
        XCTAssertTrue(notes[1].contains("\"seconds\": 0,"), notes[1])
        XCTAssertTrue(notes[2].contains("\"seconds\": 0.01,"), notes[2])
        XCTAssertTrue(notes[0].contains("\"language\": \"Hinglish\","), notes[0])
        XCTAssertTrue(notes[0].contains("\"app\": \"ThumbFree\","), notes[0])
    }

    func testKeepsNothingWhenOffFromPasswordFieldsOrAnyBrowser() {
        let cases: [(enabled: Bool, passwordField: Bool, app: TargetApp?)] = [
            (false, false, Self.outlook),
            (true, true, Self.outlook),
            (true, true, nil),
            (true, false, TargetApp(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")),
            (true, false, TargetApp(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac")),
            (true, false, TargetApp(name: "Brave Browser", bundleIdentifier: "com.brave.Browser")),
            (true, false, TargetApp(name: "", bundleIdentifier: "com.microsoft.Outlook")),
        ]
        for (enabled, passwordField, app) in cases {
            self.enabled = enabled
            let store = newStore()

            XCTAssertFalse(
                store.save(
                    [0.1, 0.2], recognized: "secret", typed: "secret", model: ModelCatalog.englishFast,
                    passwordField: passwordField, app: app))
            store.flush(timeout: 5)

            XCTAssertEqual(store.summary().count, 0)
        }
    }

    func testSamplesComeOnlyFromAppsThatAreNotBrowsersAndThumbFreesOwnBoxes() {
        let word = TargetApp(name: "Microsoft Word", bundleIdentifier: "com.microsoft.Word")
        let cases: [(app: TargetApp?, passwordField: Bool, mayKeep: Bool)] = [
            (nil, false, true),
            (word, false, true),
            (TargetApp(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"), false, true),
            (word, true, false),
            (nil, true, false),
            (TargetApp(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"), false, false),
            (TargetApp(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"), false, false),
            (TargetApp(name: "", bundleIdentifier: "com.microsoft.Word"), false, false),
            (TargetApp(name: "  ", bundleIdentifier: "com.microsoft.Word"), false, false),
            (TargetApp(name: "Example Browser", bundleIdentifier: registeredBrowser), false, false),
            // Without its bundle identifier, an app might be a browser.
            (TargetApp(name: "Microsoft Word", bundleIdentifier: nil), false, false),
        ]
        for (app, passwordField, mayKeep) in cases {
            let name = String(describing: app)
            XCTAssertEqual(SampleStore.mayKeep(app, passwordField: passwordField), mayKeep, name)
        }
    }

    func testKnowsBrowsersByBundleIdentifier() {
        let channels = [
            "com.google.Chrome.canary", "com.google.Chrome.beta", "com.microsoft.edgemac.Dev",
            "com.brave.Browser.nightly", "COM.GOOGLE.CHROME", " com.apple.Safari ", registeredBrowser,
            registeredBrowser.uppercased(),
        ]
        for identifier in BrowserList.known + channels {
            XCTAssertTrue(Browsers.isBrowser(identifier), identifier)
        }
    }

    func testOtherAppsAreNotBrowsers() {
        let others = [
            "com.microsoft.Outlook", "com.microsoft.Word", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
            "com.apple.mail", "com.google.Chromecast", "  ", "",
        ]
        for identifier in others {
            XCTAssertFalse(Browsers.isBrowser(identifier), identifier)
        }

        XCTAssertFalse(Browsers.isBrowser(nil))
    }

    func testKeepsOnlyTheNewestSamples() {
        let store = newStore(maxSamples: 10)
        for _ in 0..<15 {
            now += 1
            store.save(
                [0.1], recognized: "a", typed: "A.", model: ModelCatalog.englishLive, passwordField: false, app: nil)
        }

        store.flush(timeout: 10)

        let names = TestFiles.folders(store.folder)
        XCTAssertEqual(names.count, 10)
        XCTAssertEqual(names.first, "20261119-180006-000")
        XCTAssertEqual(names.last, "20261119-180015-000")
    }

    func testDeletesTheOldestBeyondTheSizeLimit() {
        let store = newStore(maxBytes: 100_000)
        let second = [Float](repeating: 0, count: 16000)
        for _ in 0..<5 {
            now += 1
            store.save(
                second, recognized: "a", typed: "A.", model: ModelCatalog.englishLive, passwordField: false, app: nil)
        }

        store.flush(timeout: 5)

        XCTAssertEqual(store.summary().count, 3)
        XCTAssertLessThanOrEqual(store.summary().bytes, 100_000)
    }

    func testSavesEverythingInOneZipAndDeletesAll() async throws {
        let store = newStore()
        for _ in 0..<2 {
            now += 1
            store.save(
                [0.1, -0.1], recognized: "a", typed: "A.", model: ModelCatalog.hinglish, passwordField: false, app: nil)
        }

        let zip = folder.file("out.zip")
        let count = try await store.exportZip(to: zip)
        XCTAssertEqual(count, 2)
        let listing = try TestFiles.run("/usr/bin/zipinfo", ["-1", zip])
        XCTAssertEqual(listing.status, 0, listing.output)
        XCTAssertEqual(
            listing.output.split(separator: "\n").map(String.init).sorted(),
            [
                "20261119-180001-000/audio.wav", "20261119-180001-000/meta.json", "20261119-180002-000/audio.wav",
                "20261119-180002-000/meta.json",
            ])

        // unzip reads every file back and checks it against its CRC.
        let check = try TestFiles.run("/usr/bin/unzip", ["-tq", zip])
        XCTAssertEqual(check.status, 0, check.output)

        try await store.deleteAll()
        XCTAssertEqual(store.summary().count, 0)
        XCTAssertTrue(TestFiles.exists(zip))
    }

    /// A zip without its 64-bit extension holds files under 4 GB: a bigger one is never read, and the export that
    /// meets one leaves no zip, not even a partial one.
    func testAFileOf4GBIsNeverReadAndAFailedExportLeavesNoZip() async throws {
        let store = newStore()
        let sample = folder.file("samples/20261119-180000-000")
        try FileManager.default.createDirectory(atPath: sample, withIntermediateDirectories: true)
        let big = (sample as NSString).appendingPathComponent("audio.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: big, contents: nil))

        // Sparse: it takes no room on the disk, and reading it would fill the memory with 4 GB of zeros.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: big))
        try handle.truncate(atOffset: UInt64(UInt32.max) + 1)
        try handle.close()

        let zip = folder.file("out.zip")
        do {
            _ = try await store.exportZip(to: zip)
            XCTFail("a 4 GB file went into the zip")
        } catch {
            XCTAssertTrue(error is ZipArchive.TooBig, "\(error)")
        }

        XCTAssertFalse(TestFiles.exists(zip))
        XCTAssertFalse(TestFiles.exists(zip + ".partial"))
    }

    private func newStore(maxSamples: Int = SampleStore.maxSamples, maxBytes: Int64 = SampleStore.maxBytes)
        -> SampleStore
    {
        SampleStore(
            folder: folder.file("samples"), enabled: { [unowned self] in self.enabled }, appVersion: "0.8.0",
            clock: { [unowned self] in self.now }, timeZone: india, maxSamples: maxSamples, maxBytes: maxBytes)
    }

    /// A little-endian whole number in `data`.
    private static func int(_ data: [UInt8], at offset: Int, bytes: Int) -> Int {
        (0..<bytes).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
    }
}

/// StoreTests.cs: BrowserTests. Windows reads the browsers registered in the registry, from the commands they run; the
/// Mac asks Launch Services which apps open web links, by bundle identifier, so there's no command to read.
final class BrowserTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        useTestBrowsers()
    }

    func testTheAppsThatOpenWebLinksAreReadOnceInTheBackgroundAndKept() {
        let reads = Locked(0)
        let list = BrowserList(readRegistered: {
            reads.update { $0 += 1 }
            return ["com.example.SomeBrowser", " com.example.Other "]
        })

        list.prepare()
        XCTAssertTrue(list.isBrowser("com.example.SomeBrowser"))
        XCTAssertTrue(list.isBrowser("COM.EXAMPLE.somebrowser"))
        XCTAssertTrue(list.isBrowser("com.example.Other"))
        XCTAssertFalse(list.isBrowser("com.microsoft.Word"))
        XCTAssertTrue(list.isBrowser("com.google.Chrome"))
        XCTAssertEqual(reads.value, 1)
    }

    func testLaunchServicesFailingNeverThrowsAndTheKnownBrowsersStillCount() {
        let list = BrowserList(readRegistered: { throw TestError("Launch Services didn't answer.") })

        XCTAssertFalse(list.isBrowser("com.example.SomeBrowser"))
        XCTAssertTrue(list.isBrowser("com.google.Chrome"))
    }

    func testASlowLaunchServicesNeverHoldsADictationUp() {
        let release = DispatchSemaphore(value: 0)
        let list = BrowserList(
            readRegistered: {
                release.wait()
                return ["com.example.SomeBrowser"]
            },
            wait: 0.05)

        let started = Date()
        XCTAssertFalse(list.isBrowser("com.example.SomeBrowser"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(list.isBrowser("org.mozilla.firefox"))

        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while !list.isBrowser("com.example.SomeBrowser") && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertTrue(list.isBrowser("com.example.SomeBrowser"))
    }
}
