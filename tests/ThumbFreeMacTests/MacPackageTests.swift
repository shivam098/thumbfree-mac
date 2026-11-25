import XCTest
@testable import ThumbFreeMac

final class MacPackageTests: XCTestCase {
    func testTheMacLibraryLinksTheCore() {
        XCTAssertFalse(ThumbFreeMac.coreVersion.isEmpty)
    }

    func testTheAppIsNamedAsItsBundleNamesIt() {
        // ThumbFree.app and Jarvis's app name themselves; a program run on its own has its process's name.
        let bundles: [([String: Any], String)] = [
            (["CFBundleDisplayName": "Jarvis", "CFBundleName": "VoiceAssistant"], "Jarvis"),
            (["CFBundleDisplayName": " ", "CFBundleName": "ThumbFree"], "ThumbFree"),
            (["CFBundleName": 3], "swift-run-name"),
            ([:], "swift-run-name"),
        ]
        for (info, name) in bundles {
            XCTAssertEqual(name, ThumbFreeMac.nameOfApp(info: { info[$0] }, processName: "swift-run-name"), "\(info)")
        }

        XCTAssertEqual("This app", ThumbFreeMac.nameOfApp(info: { _ in nil }, processName: ""))
        XCTAssertFalse(ThumbFreeMac.appName.isEmpty)
    }
}
