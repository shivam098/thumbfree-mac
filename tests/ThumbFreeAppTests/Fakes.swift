import Foundation
import XCTest
import ThumbFreeCore
@testable import ThumbFreeApp

/// macOS as tests see it (thumbfree-windows tests' FakeEnvironment): nothing touches the pasteboard, the login items
/// or the screen; answers are scripted.
final class FakeEnvironment: AppEnvironment, @unchecked Sendable {
    private let copies = Locked<[(text: String, concealed: Bool)]>([])
    var opened: [URL] = []
    var questions: [Confirmation] = []
    var answer = true
    var savePath: String?
    var startsAtLogin = false
    var totalMemoryBytes: Int64 = 16 << 30
    var metered = false
    var microphone = MicrophoneAccess.allowed
    var notifications = true

    var copied: [String] { copies.value.map(\.text) }

    /// For each copy, whether it was concealed from clipboard managers.
    var concealed: [Bool] { copies.value.map(\.concealed) }

    func copyText(_ text: String, concealed: Bool) {
        copies.update { $0.append((text: text, concealed: concealed)) }
    }

    func open(_ url: URL) {
        opened.append(url)
    }

    func showInFinder(_ path: String) {
        opened.append(URL(fileURLWithPath: path))
    }

    func isMeteredConnection() -> Bool { metered }

    func checkMicrophone() -> MicrophoneAccess { microphone }

    func notificationsEnabled() -> Bool { notifications }

    func confirm(_ question: Confirmation) -> Bool {
        questions.append(question)
        return answer
    }

    func askSavePath(title: String, fileName: String) -> String? { savePath }
}

/// Models that are "installed" when listed; downloads finish when told to, or fail with `failure`.
final class FakeModelManager: ModelManager, @unchecked Sendable {
    private let lock = NSLock()
    private var installedIds: Set<String> = []
    private var failing: Error?
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private var cancelledEarly: Set<String> = []
    private var progress: [String: @Sendable (Double) -> Void] = [:]

    var onChange: ((ModelSpec) -> Void)?

    var failure: Error? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func install(_ spec: ModelSpec) {
        lock.withLock { _ = installedIds.insert(spec.id) }
    }

    func isInstalled(_ spec: ModelSpec) -> Bool { lock.withLock { installedIds.contains(spec.id) } }

    func download(_ spec: ModelSpec, progress report: @escaping @Sendable (Double) -> Void) async throws {
        if let failure {
            throw failure
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled: Bool = self.lock.withLock {
                    if self.cancelledEarly.remove(spec.id) != nil {
                        return true
                    }

                    self.waiting[spec.id] = continuation
                    self.progress[spec.id] = report
                    return false
                }

                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = self.lock.withLock {
                guard let continuation = self.waiting.removeValue(forKey: spec.id) else {
                    self.cancelledEarly.insert(spec.id)
                    return nil
                }

                return continuation
            }

            continuation?.resume(throwing: CancellationError())
        }

        install(spec)
    }

    /// Waits until the download has started (it runs in a task of its own).
    func waitStarted(_ spec: ModelSpec, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<500 {
            if lock.withLock({ waiting[spec.id] != nil }) {
                return
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTFail("The download never started.", file: file, line: line)
    }

    func report(_ spec: ModelSpec, _ value: Double) {
        waitStarted(spec)
        lock.withLock { progress[spec.id] }?(value)
    }

    func finish(_ spec: ModelSpec) {
        waitStarted(spec)
        lock.withLock { waiting.removeValue(forKey: spec.id) }?.resume()
    }

    func delete(_ spec: ModelSpec) throws {
        lock.withLock { _ = installedIds.remove(spec.id) }
        onChange?(spec)
    }
}

/// Notifications that are recorded instead of shown.
final class FakeSurface: NotificationSurface, @unchecked Sendable {
    typealias Shown = (title: String, text: String, warning: Bool, tag: String?)

    private let lock = NSLock()
    private var shownList: [Shown] = []
    private var hiddenCount = 0

    var onClicked: ((String?) -> Void)?

    var shown: [Shown] { lock.withLock { shownList } }

    var hidden: Int { lock.withLock { hiddenCount } }

    func show(_ title: String, _ text: String, warning: Bool, tag: String?) {
        lock.withLock { shownList.append((title: title, text: text, warning: warning, tag: tag)) }
    }

    func hide() {
        lock.withLock { hiddenCount += 1 }
    }

    /// A click on the notification shown last.
    func click() {
        onClicked?(shown.last?.tag)
    }
}

/// Builds `AppServices` on temporary files with fakes.
enum TestServices {
    static func create(
        _ folder: TempFolder,
        environment: FakeEnvironment = FakeEnvironment(),
        models: ModelManager = FakeModelManager(),
        settings: AppSettings = AppSettings(),
        clock: @escaping () -> Date = Date.init
    ) -> AppServices {
        let store = SettingsStore(settings, path: folder.file("settings.json"))
        return AppServices(
            settings: store,
            history: HistoryStore(
                path: folder.file("history.txt"), enabled: { store.current.keepHistory }, clock: clock),
            samples: SampleStore(
                folder: folder.file("samples"), enabled: { store.current.saveSamples }, appVersion: "0.8.0",
                clock: clock),
            models: ModelDownloads(models),
            state: DictationState(),
            environment: environment,
            appVersion: "0.8.0")
    }
}

/// Waits (5 s at most) until `condition` holds, as the Windows tests' WaitForAsync does.
func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }

    XCTAssertTrue(condition(), "timed out", file: file, line: line)
}
