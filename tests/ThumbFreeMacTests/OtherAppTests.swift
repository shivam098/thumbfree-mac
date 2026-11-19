import XCTest
@testable import ThumbFreeMac

/// The running apps, as the tests launch and quit them.
final class FakeOtherAppWorkspace: OtherApp.Workspace {
    private(set) var running: [String: [pid_t]] = [:]
    private var handler: (@MainActor @Sendable (OtherApp.Change, String?, pid_t) -> Void)?

    var isObserving: Bool {
        handler != nil
    }

    func processes(bundleIdentifier: String) -> [pid_t] {
        running[bundleIdentifier] ?? []
    }

    func observe(_ handler: @escaping @MainActor @Sendable (OtherApp.Change, String?, pid_t) -> Void) {
        self.handler = handler
    }

    func stopObserving() {
        handler = nil
    }

    /// An app that was running before anyone watched.
    func alreadyRunning(_ bundleIdentifier: String, _ processIdentifier: pid_t) {
        running[bundleIdentifier, default: []].append(processIdentifier)
    }

    @MainActor
    func launch(_ bundleIdentifier: String?, _ processIdentifier: pid_t) {
        if let bundleIdentifier {
            alreadyRunning(bundleIdentifier, processIdentifier)
        }

        handler?(.launched, bundleIdentifier, processIdentifier)
    }

    @MainActor
    func quit(_ bundleIdentifier: String?, _ processIdentifier: pid_t) {
        if let bundleIdentifier {
            running[bundleIdentifier]?.removeAll { $0 == processIdentifier }
        }

        handler?(.quit, bundleIdentifier, processIdentifier)
    }
}

final class OtherAppTests: XCTestCase {
    private let jarvis = ThumbFreeMac.jarvisBundleIdentifier
    private let thumbFree = ThumbFreeMac.thumbFreeBundleIdentifier

    @MainActor
    private func watchJarvis(_ workspace: FakeOtherAppWorkspace) -> (OtherApp, Changes) {
        let other = OtherApp(otherThan: thumbFree, workspace: workspace)!
        let changes = Changes()
        other.onChange = { running in changes.list.append(running) }
        other.start()
        return (other, changes)
    }

    @MainActor
    private final class Changes {
        var list: [Bool] = []
    }

    func testEachAppWatchesTheOther() {
        XCTAssertEqual(jarvis, OtherApp.otherBundleIdentifier(of: thumbFree))
        XCTAssertEqual(thumbFree, OtherApp.otherBundleIdentifier(of: jarvis))
        XCTAssertNil(OtherApp.otherBundleIdentifier(of: "com.apple.TextEdit"))
        XCTAssertNil(OtherApp.otherBundleIdentifier(of: nil))
    }

    @MainActor
    func testTellsAtTheStartWhetherTheOtherAppIsRunning() {
        let workspace = FakeOtherAppWorkspace()
        workspace.alreadyRunning(jarvis, 501)
        let (other, changes) = watchJarvis(workspace)

        XCTAssertEqual(jarvis, other.bundleIdentifier)
        XCTAssertTrue(other.isRunning)
        XCTAssertEqual([], changes.list)
        XCTAssertNil(OtherApp(otherThan: "com.apple.TextEdit", workspace: workspace))
    }

    @MainActor
    func testFollowsTheOtherAppLaunchingAndQuitting() {
        let workspace = FakeOtherAppWorkspace()
        let (other, changes) = watchJarvis(workspace)
        XCTAssertFalse(other.isRunning)

        workspace.launch(jarvis, 600)
        workspace.launch("com.apple.Safari", 601)
        workspace.launch(nil, 602)
        workspace.quit("com.apple.Safari", 601)
        XCTAssertTrue(other.isRunning)
        workspace.quit(jarvis, 600)

        XCTAssertFalse(other.isRunning)
        XCTAssertEqual([true, false], changes.list)
    }

    @MainActor
    func testTwoCopiesCountUntilBothHaveQuit() {
        let workspace = FakeOtherAppWorkspace()
        workspace.alreadyRunning(jarvis, 700)
        let (other, changes) = watchJarvis(workspace)

        workspace.launch(jarvis, 701)
        workspace.quit(jarvis, 700)
        XCTAssertTrue(other.isRunning)
        workspace.quit(jarvis, 701)

        XCTAssertEqual([false], changes.list)
    }

    @MainActor
    func testThisProcessNeverCounts() {
        let workspace = FakeOtherAppWorkspace()
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        workspace.alreadyRunning(jarvis, ownProcess)
        let (other, changes) = watchJarvis(workspace)

        workspace.launch(jarvis, ownProcess)

        XCTAssertFalse(other.isRunning)
        XCTAssertEqual([], changes.list)
    }

    @MainActor
    func testStopEndsTheWatch() {
        let workspace = FakeOtherAppWorkspace()
        let (other, changes) = watchJarvis(workspace)
        XCTAssertTrue(workspace.isObserving)

        other.stop()
        workspace.launch(jarvis, 800)

        XCTAssertFalse(workspace.isObserving)
        XCTAssertFalse(other.isRunning)
        XCTAssertEqual([], changes.list)

        other.start()
        XCTAssertTrue(other.isRunning)
    }
}
