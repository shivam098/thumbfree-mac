import AVFoundation
import XCTest
@testable import ThumbFreeMac

/// What macOS answers, as the tests set it, and what was asked of it.
final class FakePermissionsSystem: Permissions.System, @unchecked Sendable {
    var microphone = AVAuthorizationStatus.notDetermined
    /// The person's answer to the microphone prompt.
    var allowsMicrophone = true
    var trusted = false
    var posting = false
    /// The person's answer to the event-posting prompt.
    var allowsPosting = false
    var listening = false
    /// The person's answer to the Input Monitoring prompt.
    var allowsListening = false
    private(set) var prompts: [Permissions.Kind] = []
    private(set) var opened: [String] = []

    func microphoneStatus() -> AVAuthorizationStatus {
        microphone
    }

    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        prompts.append(.microphone)
        let answer = allowsMicrophone
        // AVFoundation answers on a queue of its own.
        DispatchQueue.global().async {
            completion(answer)
        }
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if prompt && !trusted {
            prompts.append(.accessibility)
        }

        return trusted
    }

    func canPostEvents() -> Bool {
        posting
    }

    func requestPostEvents() -> Bool {
        prompts.append(.postEvents)
        posting = allowsPosting
        return posting
    }

    func canListenToEvents() -> Bool {
        listening
    }

    func requestListenToEvents() -> Bool {
        prompts.append(.inputMonitoring)
        listening = allowsListening
        return listening
    }

    func open(_ url: URL) -> Bool {
        opened.append(url.absoluteString)
        return true
    }
}

final class PermissionsTests: XCTestCase {
    /// Asks for `kind` and waits for the answer, which must come on the main thread.
    @MainActor
    private func request(_ kind: Permissions.Kind, from permissions: Permissions) -> Permissions.Status? {
        let answered = expectation(description: "answered")
        let answer = Answer()
        permissions.request(kind) { status in
            answer.status = status
            answer.onMainThread = Thread.isMainThread
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        XCTAssertTrue(answer.onMainThread)
        return answer.status
    }

    @MainActor
    private final class Answer {
        var status: Permissions.Status?
        var onMainThread = false
    }

    func testStatusIsWhatMacOSSaysAndNeverPrompts() {
        let system = FakePermissionsSystem()
        let permissions = Permissions(system: system)
        let microphone: [(AVAuthorizationStatus, Permissions.Status)] = [
            (.authorized, .granted), (.notDetermined, .notDetermined), (.denied, .denied), (.restricted, .denied),
        ]
        for (answer, status) in microphone {
            system.microphone = answer
            XCTAssertEqual(status, permissions.status(.microphone))
        }

        XCTAssertEqual(.denied, permissions.status(.accessibility))
        XCTAssertEqual(.denied, permissions.status(.postEvents))
        XCTAssertEqual(.denied, permissions.status(.inputMonitoring))
        system.trusted = true
        XCTAssertEqual(.granted, permissions.status(.accessibility))
        // Checked apart, even though System Settings shows both as one switch.
        XCTAssertEqual(.denied, permissions.status(.postEvents))
        system.posting = true
        system.listening = true
        XCTAssertEqual(.granted, permissions.status(.postEvents))
        XCTAssertEqual(.granted, permissions.status(.inputMonitoring))
        XCTAssertEqual([], system.prompts)
    }

    func testEachPermissionOpensItsOwnListInSystemSettings() {
        let system = FakePermissionsSystem()
        let permissions = Permissions(system: system)

        for kind in Permissions.Kind.allCases {
            XCTAssertTrue(permissions.openSettings(kind))
        }

        XCTAssertEqual([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ], system.opened)
    }

    @MainActor
    func testTheMicrophonePromptShowsOnlyWhenMacOSHasNotAskedYet() {
        let system = FakePermissionsSystem()
        let permissions = Permissions(system: system)

        XCTAssertEqual(.granted, request(.microphone, from: permissions))
        system.allowsMicrophone = false
        XCTAssertEqual(.denied, request(.microphone, from: permissions))
        XCTAssertEqual([.microphone, .microphone], system.prompts)

        system.microphone = .denied
        XCTAssertEqual(.denied, request(.microphone, from: permissions))
        system.microphone = .authorized
        XCTAssertEqual(.granted, request(.microphone, from: permissions))
        XCTAssertEqual([.microphone, .microphone], system.prompts)
    }

    @MainActor
    func testAccessibilityPostingAndInputMonitoringShowMacOSsPromptUntilGranted() {
        let system = FakePermissionsSystem()
        let permissions = Permissions(system: system)

        XCTAssertEqual(.denied, request(.accessibility, from: permissions))
        XCTAssertEqual(.denied, request(.postEvents, from: permissions))
        XCTAssertEqual(.denied, request(.inputMonitoring, from: permissions))
        XCTAssertEqual([.accessibility, .postEvents, .inputMonitoring], system.prompts)

        system.trusted = true
        system.allowsPosting = true
        system.allowsListening = true
        XCTAssertEqual(.granted, request(.accessibility, from: permissions))
        XCTAssertEqual(.granted, request(.postEvents, from: permissions))
        XCTAssertEqual(.granted, request(.inputMonitoring, from: permissions))
        // Granted already: no more prompts.
        XCTAssertEqual(.granted, request(.postEvents, from: permissions))
        XCTAssertEqual(.granted, request(.inputMonitoring, from: permissions))
        XCTAssertEqual([.accessibility, .postEvents, .inputMonitoring, .postEvents, .inputMonitoring], system.prompts)
    }
}
