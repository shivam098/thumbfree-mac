import XCTest
import ThumbFreeCore
@testable import ThumbFreeApp

/// thumbfree-windows tests/ThumbFree.App.Tests/StoreTests.cs: NotifierTests.
final class NotifierTests: XCTestCase {
    private let surface = FakeSurface()
    private let state = DictationState()
    private let copied = Locked<[String]>([])

    private func makeNotifier() -> Notifier {
        let copied = self.copied
        return Notifier(surface: surface, state: state, copy: { text in copied.update { $0.append(text) } }, queue: nil)
    }

    func testTextThatCouldntBeTypedIsKeptAndAClickCopiesIt() throws {
        let notifier = makeNotifier()

        notifier.showUntyped("Hey Tim, would love to connect.")
        XCTAssertEqual(notifier.untypedText, "Hey Tim, would love to connect.")
        let text = try XCTUnwrap(surface.shown.first).text
        XCTAssertTrue(text.contains("The text box closed before your text was ready. Click to copy it."), text)
        XCTAssertFalse(text.contains("Tim"))

        surface.click()
        XCTAssertEqual(copied.value, ["Hey Tim, would love to connect."])
        XCTAssertNil(notifier.untypedText)
        XCTAssertEqual(surface.shown.last?.title, "Copied")

        // A click on the "Copied" confirmation does nothing more.
        surface.click()
        XCTAssertEqual(copied.value.count, 1)
    }

    func testTheMicrophoneWarningShowsOnceAndGoesWhenSoundReturns() {
        let notifier = makeNotifier()

        notifier.showMicrophoneSilent()
        notifier.showMicrophoneSilent()
        XCTAssertTrue(state.microphoneSilent)
        XCTAssertEqual(surface.shown.count, 1)
        XCTAssertEqual(surface.shown.first?.text, "No sound from the microphone. Is another app or a call using it?")

        notifier.clearMicrophoneSilent()
        XCTAssertFalse(state.microphoneSilent)
        XCTAssertEqual(surface.hidden, 1)
    }

    func testClearingTheWarningAfterKeptTextNeverTakesTheKeptTextBack() {
        let notifier = makeNotifier()

        notifier.showUntyped("Call me at 4 PM.")
        notifier.showMicrophoneSilent()
        notifier.clearMicrophoneSilent()

        XCTAssertEqual(surface.hidden, 0)
        XCTAssertFalse(state.microphoneSilent)
        XCTAssertEqual(notifier.untypedText, "Call me at 4 PM.")

        // A click on the warning (shown last) still copies, as Windows reports only that one.
        surface.click()
        XCTAssertEqual(copied.value, ["Call me at 4 PM."])
        XCTAssertEqual(surface.hidden, 1)
        XCTAssertEqual(surface.shown.last?.title, "Copied")
    }

    func testCopyingKeptTextNeverTakesBackAWarningThatIsStillTrue() {
        let notifier = makeNotifier()

        notifier.showUntyped("Call me at 4 PM.")
        notifier.showMicrophoneSilent()
        notifier.clearMicrophoneSilent()
        notifier.showMicrophoneSilent()

        XCTAssertTrue(notifier.copyUntyped())
        XCTAssertEqual(surface.hidden, 0)
        XCTAssertTrue(state.microphoneSilent)
    }

    func testOnceTheKeptTextIsCopiedClearingTakesTheWarningBack() {
        let notifier = makeNotifier()

        notifier.showUntyped("Call me at 4 PM.")
        notifier.copyUntyped()
        notifier.showMicrophoneSilent()
        notifier.clearMicrophoneSilent()

        XCTAssertEqual(surface.hidden, 1)
    }

    func testClearingTheWarningNeverTakesBackKeptText() {
        let notifier = makeNotifier()

        notifier.showMicrophoneSilent()
        notifier.showUntyped("Call me at 4 PM.", reason: "That app didn't accept the text.")
        notifier.clearMicrophoneSilent()

        XCTAssertEqual(surface.hidden, 0)
        XCTAssertTrue(surface.shown.last?.text.hasPrefix("That app didn't accept the text.") == true)
        XCTAssertTrue(notifier.copyUntyped())
        XCTAssertEqual(copied.value, ["Call me at 4 PM."])
    }
}

/// StoreTests.cs: ModelTests. The Mac's downloads are Swift tasks, waited for here as the Windows tests await theirs.
final class ModelTests: XCTestCase {
    func testADownloadShowsProgressThenTheModelIsInstalled() {
        let models = FakeModelManager()
        let downloads = ModelDownloads(models)
        let spec = ModelCatalog.englishLive

        let task = downloads.start(spec)
        XCTAssertEqual(task, downloads.start(spec))
        XCTAssertEqual(downloads.state(spec).status, .downloading)
        models.report(spec, 0.5)
        XCTAssertEqual(downloads.state(spec).progress, 0.5)

        models.finish(spec)
        waitForDownload(task)
        XCTAssertEqual(downloads.state(spec).status, .installed)
    }

    func testCancellingLeavesNoErrorAndAFailureSaysWhatToDo() throws {
        let models = FakeModelManager()
        let downloads = ModelDownloads(models)
        let spec = ModelCatalog.hinglish

        let task = downloads.start(spec)
        models.waitStarted(spec)
        downloads.cancel(spec)
        waitForDownload(task)
        XCTAssertEqual(downloads.state(spec), ModelState(.notInstalled))

        models.failure = URLError(.badServerResponse)
        waitForDownload(downloads.start(spec))
        let error = try XCTUnwrap(downloads.state(spec).error)
        XCTAssertTrue(error.contains("internet connection"), error)
    }

    func testADownloadThatStopsByItselfIsAnErrorNotACancel() {
        // Not the person's Cancel: the task ended without being asked to.
        let models = FakeModelManager()
        models.failure = CancellationError()
        let downloads = ModelDownloads(models)

        waitForDownload(downloads.start(ModelCatalog.englishLive))

        XCTAssertEqual(
            downloads.state(ModelCatalog.englishLive),
            ModelState(.notInstalled, error: "The download stalled. Try again."))
    }

    func testOnlyBigModelsAskFirstWithSizeMemoryAndData() {
        XCTAssertEqual(
            ModelCatalog.all.filter(ModelConsent.needed), [ModelCatalog.englishAccurate, ModelCatalog.hinglishAccurate])

        let low = ModelConsent.message(ModelCatalog.englishAccurate, totalMemoryBytes: 4 << 30, metered: true)
        XCTAssertTrue(low.contains("661 MB"), low)
        XCTAssertTrue(low.contains("This Mac has 4 GB of memory. That may not be enough (6 GB or more is best)"), low)
        XCTAssertTrue(low.contains("metered connection"), low)

        let plenty = ModelConsent.message(ModelCatalog.hinglishAccurate, totalMemoryBytes: 32 << 30, metered: false)
        XCTAssertTrue(plenty.contains("This Mac has 32 GB of memory. That's enough."), plenty)
        XCTAssertFalse(plenty.contains("metered"), plenty)
        XCTAssertEqual(ModelConsent.title(ModelCatalog.hinglishAccurate), "Download “Hindi + English, accurate”?")
        XCTAssertEqual(ModelConsent.mb(ModelCatalog.englishLive.bytes), "79 MB")
    }

    /// Waits for a download's task, which never fails, 10 s at most.
    private func waitForDownload(_ task: Task<Void, Never>, file: StaticString = #filePath, line: UInt = #line) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await task.value
            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "the download didn't end", file: file, line: line)
    }
}
