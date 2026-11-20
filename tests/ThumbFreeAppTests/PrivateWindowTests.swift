import XCTest
@testable import ThumbFreeApp

/// Which browser windows History leaves out (`PrivateWindows`), from their AXTitles as each browser makes them, in its
/// languages; a browser window that can't be told apart from a private one counts as one.
final class PrivateWindowTests: XCTestCase {
    private var folder: TempFolder!
    private var firefoxFolder: String!

    override func setUp() {
        useTestBrowsers()
        folder = TempFolder()
        firefoxFolder = PrivateWindows.firefoxFolder.value
        PrivateWindows.firefoxFolder.value = folder.path
    }

    override func tearDown() {
        PrivateWindows.firefoxFolder.value = firefoxFolder
        folder.remove()
    }

    func testChromeAndBraveSayInEveryLanguageWhenAWindowKeepsNoHistory() {
        let kept: [(bundle: String, title: String)] = [
            ("com.google.Chrome", "Inbox (3) - Google Chrome"),
            ("com.google.Chrome", "Inbox - Google Chrome - Work"),
            ("com.google.Chrome", "Posteingang - Google Chrome"),
            ("com.google.Chrome", "받은편지함 - Chrome"),
            ("com.google.Chrome.beta", "Inbox – Google Chrome Beta"),
            ("org.chromium.Chromium", "Inbox - Chromium"),
            ("org.chromium.Chromium", "इनबॉक्स - क्रोमियम"),
            ("com.brave.Browser", "Inbox - Brave"),
            ("com.brave.Browser.nightly", "Inbox - Brave Canary"),
        ]
        for (bundle, title) in kept {
            XCTAssertNil(reason(bundle, title), title)
        }

        let offTheRecord: [(bundle: String, title: String)] = [
            ("com.google.Chrome", "Inbox - Google Chrome (Incognito)"),
            ("com.google.Chrome", "Inbox - Google Chrome (Guest)"),
            ("com.google.Chrome", "Posteingang - Google Chrome (anonym)"),
            ("com.google.Chrome", "受信トレイ - Google Chrome（シークレット モード）"),
            ("com.google.Chrome", "इनबॉक्स - Google Chrome (गुप्त)"),
            ("com.google.Chrome", "(Зочин) Inbox - Google Chrome"),
            ("com.google.Chrome.canary", "Inbox – Google Chrome Canary (Incognito)"),
            ("org.chromium.Chromium", "Inbox - Chromium (Incognito)"),
            ("com.brave.Browser", "Inbox - Brave (Private)"),
            ("com.brave.Browser", "Posteingang - Brave (Privat)"),
        ]
        for (bundle, title) in offTheRecord {
            XCTAssertEqual(reason(bundle, title), .privateWindow, title)
        }

        // A title that isn't the browser window's, as Chromium makes it (a dialog's, an app's), can't tell.
        XCTAssertEqual(reason("com.google.Chrome", "Sign in"), .cantTell)
    }

    func testFirefoxSaysWhenAWindowIsPrivateUnlessItNeverRemembersHistory() throws {
        for bundle in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"] {
            XCTAssertNil(reason(bundle, "Inbox"), bundle)
            XCTAssertNil(reason(bundle, "Mozilla Firefox"), bundle)
            XCTAssertEqual(reason(bundle, "Inbox — Private Browsing"), .privateWindow, bundle)
        }

        let privateTitles = [
            "Mozilla Firefox — Private Browsing", "Inbox — Work — Private Browsing", "Posteingang — Privater Modus",
            "Mozilla Firefox – Privater Modus", "Mozilla Firefox — Navigation privée de Mozilla Firefox",
            "受信トレイ — プライベートブラウジング",
        ]
        for title in privateTitles {
            XCTAssertEqual(reason("org.mozilla.firefox", title), .privateWindow, title)
        }

        // "Never remember history" makes every window private, and its titles say nothing.
        let profile = folder.file("Profiles/abcd1234.default-release")
        let prefs = (profile as NSString).appendingPathComponent("prefs.js")
        TestFiles.write(prefs, "user_pref(\"browser.privatebrowsing.autostart\", false);\n")
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))
        TestFiles.write(prefs, "user_pref(\"app.shield.optoutstudies.enabled\", false);\n"
            + "user_pref(\"browser.privatebrowsing.autostart\", true);\n")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: prefs)
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
    }

    func testAFirefoxProfileListedInProfilesIniAnywhereIsRead() {
        let elsewhere = folder.file("Elsewhere/work")
        TestFiles.write(
            folder.file("profiles.ini"),
            "[Profile0]\nName=work\nIsRelative=0\nPath=\(elsewhere)\n\n[Profile1]\nName=default\nIsRelative=1\n"
                + "Path=Profiles/xyz.default\n")
        TestFiles.write(folder.file("Profiles/xyz.default/prefs.js"), "")
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))

        TestFiles.write(
            (elsewhere as NSString).appendingPathComponent("prefs.js"),
            "user_pref(\"browser.privatebrowsing.autostart\", true);\n")
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
    }

    func testBrowsersWhosePrivateWindowsCantBeToldApartAreNeverKept() {
        let unknown = [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.microsoft.edgemac",
            "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
            "com.duckduckgo.macos.browser", "com.kagi.kagimacOS", "app.zen-browser.zen", registeredBrowser,
        ]
        for bundle in unknown {
            XCTAssertEqual(reason(bundle, "Inbox"), .cantTell, bundle)
        }

        XCTAssertEqual(reason("org.torproject.torbrowser", "Inbox — Tor Browser"), .alwaysPrivate)
        XCTAssertEqual(reason("net.mullvad.mullvadbrowser", "Inbox — Mullvad Browser"), .alwaysPrivate)
    }

    func testABrowserWindowWhoseTitleCantBeReadCountsAsPrivate() {
        for title in [nil, "", "  "] as [String?] {
            XCTAssertEqual(reason("com.google.Chrome", title), .noTitle)
            XCTAssertEqual(reason("org.mozilla.firefox", title), .noTitle)
        }
    }

    func testAppsThatArentBrowsersHaveNoPrivateWindows() {
        XCTAssertNil(reason("com.apple.mail", "Incognito mode — Private Browsing"))
        XCTAssertNil(reason("com.apple.Notes", "Notes (Incognito)"))
        XCTAssertNil(reason("com.tinyspeck.slackmacgap", nil))
        XCTAssertNil(reason(nil, nil))
        let mail = TargetApp(name: "Mail", bundleIdentifier: "com.apple.mail")
        let safari = TargetApp(name: "Safari", bundleIdentifier: "com.apple.Safari")
        XCTAssertFalse(PrivateWindows.mayBePrivate(mail, title: nil))
        XCTAssertTrue(PrivateWindows.mayBePrivate(safari, title: "Inbox"))
    }

    private func reason(_ bundle: String?, _ title: String?) -> PrivateWindows.Reason? {
        PrivateWindows.reason(TargetApp(name: "App", bundleIdentifier: bundle), title: title)
    }
}
