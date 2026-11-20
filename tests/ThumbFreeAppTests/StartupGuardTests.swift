import XCTest
@testable import ThumbFreeApp

/// thumbfree-windows tests/ThumbFree.App.Tests/StartupGuardTests.cs, with the menu-bar item for the tray icon.
final class StartupGuardTests: XCTestCase {
    private var shown: [String] = []
    private var exits = 0

    func testAFailureBeforeTheMenuBarItemExistsSaysWhatWentWrongAndQuits() {
        let logs = AppPaths.standard.logs
        let startup = StartupGuard(logs: logs, showError: { self.shown.append($0) }, quit: { self.exits += 1 })

        XCTAssertTrue(
            startup.handle(TestError("Access to the path 'settings.json' is denied."), menuBarExists: false))

        XCTAssertEqual(exits, 1)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown[0].hasPrefix("ThumbFree couldn't start: Access to the path 'settings.json' is denied."))
        XCTAssertTrue(shown[0].contains(logs))
    }

    func testItQuitsEvenWhenTheErrorAlertFails() {
        let startup = StartupGuard(
            logs: AppPaths.standard.logs, showError: { _ in throw TestError("no screen") }, quit: { self.exits += 1 })

        XCTAssertTrue(startup.handle(TestError("disk"), menuBarExists: false))

        XCTAssertEqual(exits, 1)
    }

    func testOnceTheMenuBarItemExistsTheUsualHandlingApplies() {
        let startup = StartupGuard(
            logs: AppPaths.standard.logs, showError: { self.shown.append($0) }, quit: { self.exits += 1 })

        XCTAssertFalse(startup.handle(TestError("disk"), menuBarExists: true))

        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(exits, 0)
    }
}
