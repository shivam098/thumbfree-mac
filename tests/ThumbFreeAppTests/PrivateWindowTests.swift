import XCTest
@testable import ThumbFreeApp

/// Which browser windows History leaves out (`PrivateWindows`), from their AXTitles as each browser makes them, in its
/// languages; a browser window that can't be told apart from a private one counts as one.
final class PrivateWindowTests: XCTestCase {
    private var folder: TempFolder!
    private var firefoxFolder: String!
    private var firefoxApps: ((String) -> [String])!
    private var firefoxPolicyDomain: ((String) -> String)!
    private var domain = ""
    private var changes = 0

    override func setUp() {
        useTestBrowsers()
        folder = TempFolder()
        firefoxFolder = PrivateWindows.firefoxFolder.value
        firefoxApps = PrivateWindows.firefoxApps.value
        firefoxPolicyDomain = PrivateWindows.firefoxPolicyDomain.value
        PrivateWindows.firefoxFolder.value = folder.path
        let app = folder.file("Firefox.app")
        PrivateWindows.firefoxApps.value = { _ in [app] }
        let domain = "app.thumbfree.tests.firefox-" + UUID().uuidString
        self.domain = domain
        PrivateWindows.firefoxPolicyDomain.value = { _ in domain }
    }

    override func tearDown() {
        for key in Self.policyKeys {
            setPreference(key, nil)
        }

        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(domain).plist")
        PrivateWindows.firefoxFolder.value = firefoxFolder
        PrivateWindows.firefoxApps.value = firefoxApps
        PrivateWindows.firefoxPolicyDomain.value = firefoxPolicyDomain
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

    /// Firefox's administrator can make every window private, which prefs.js never shows: a policy in the app's
    /// distribution/policies.json. One that can't be read or parsed counts as doing so.
    func testFirefoxMadePrivateByAPolicyInItsPoliciesFileIsNeverKept() throws {
        let policies = folder.file("Firefox.app/Contents/Resources/distribution/policies.json")
        let preference = #""Preferences": {"browser.privatebrowsing.autostart""#
        let cases: [(json: String, forced: Bool)] = [
            (#"{"policies": {"DisableAppUpdate": true}}"#, false),
            (#"{"policies": {"PrivateBrowsingModeAvailability": 2}}"#, true),
            (#"{"policies": {"PrivateBrowsingModeAvailability": 1}}"#, false),
            (#"{"policies": {\#(preference): {"Value": true, "Status": "locked"}}}}"#, true),
            (#"{"policies": {\#(preference): {"Value": true, "Status": "clear"}}}}"#, false),
            (#"{"policies": {\#(preference): true}}}"#, true),
            (#"{"policies": {\#(preference): false}}}"#, false),
            (#"{"policies": {"#, true),
        ]
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))
        for (json, forced) in cases {
            write(policies, json)
            XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), forced ? .alwaysPrivate : nil, json)
        }

        // Root could read it anyway.
        if getuid() != 0 {
            write(policies, #"{"policies": {}}"#)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: policies)
            XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: policies)
        }
    }

    /// The same policies in macOS preferences for Firefox's bundle identifier (a configuration profile, or `defaults`),
    /// which count once EnterprisePoliciesEnabled is true, the Preferences policy flat or not.
    func testFirefoxMadePrivateByAPolicyInMacOSPreferencesIsNeverKept() {
        setPreference("PrivateBrowsingModeAvailability", NSNumber(value: 2))
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))

        setPreference("EnterprisePoliciesEnabled", kCFBooleanTrue)
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
        setPreference("PrivateBrowsingModeAvailability", NSNumber(value: 0))
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))

        // macOS preferences give true as 1.
        setPreference("Preferences__browser.privatebrowsing.autostart__Value", NSNumber(value: 1))
        setPreference("Preferences__browser.privatebrowsing.autostart__Status", "locked" as NSString)
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
        setPreference("Preferences__browser.privatebrowsing.autostart__Status", "clear" as NSString)
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))
    }

    /// AutoConfig too: a .cfg named in the app's defaults/pref files, its bytes shifted by 13 unless they say
    /// otherwise, that sets the preference, or loads more from a server, which can't be seen.
    func testFirefoxMadePrivateByAutoConfigIsNeverKept() {
        let resources = folder.file("Firefox.app/Contents/Resources") as NSString
        let defaults = resources.appendingPathComponent("defaults/pref") as NSString
        let autoconfig = defaults.appendingPathComponent("autoconfig.js")
        let cfg = resources.appendingPathComponent("mozilla.cfg")
        write(defaults.appendingPathComponent("channel-prefs.js"), #"pref("app.update.channel", "release");"#)
        write(
            autoconfig,
            #"pref("general.config.filename", "mozilla.cfg");"# + "\n" + #"pref("general.config.obscure_value", 0);"#)
        write(cfg, "// AutoConfig\n" + #"lockPref("browser.startup.homepage", "https://example.com");"#)
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))

        write(cfg, "// AutoConfig\n" + #"lockPref("browser.privatebrowsing.autostart", true);"#)
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
        write(cfg, "// AutoConfig\n" + #"lockPref("autoadmin.global_config_url", "https://example.com/firefox.js");"#)
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)

        // Without general.config.obscure_value, each byte of the .cfg is shifted by 13.
        write(autoconfig, "pref('general.config.filename', 'mozilla.cfg');")
        let shifted = "// AutoConfig\ndefaultPref('browser.privatebrowsing.autostart', true);"
        write(cfg, bytes: shifted.utf8.map { $0 &+ 13 })
        XCTAssertEqual(reason("org.mozilla.firefox", "Inbox"), .alwaysPrivate)
        write(cfg, bytes: "// AutoConfig\n".utf8.map { $0 &+ 13 })
        XCTAssertNil(reason("org.mozilla.firefox", "Inbox"))
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

    private static let policyKeys = [
        "EnterprisePoliciesEnabled", "PrivateBrowsingModeAvailability",
        "Preferences__browser.privatebrowsing.autostart__Value",
        "Preferences__browser.privatebrowsing.autostart__Status",
    ]

    /// Writes a file as a change that what's been read of it can't miss, however soon after the last.
    private func write(_ path: String, _ text: String) {
        write(path, bytes: Array(text.utf8))
    }

    private func write(_ path: String, bytes: [UInt8]) {
        TestFiles.write(path, bytes: bytes)
        changes += 1
        XCTAssertNoThrow(
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(changes))], ofItemAtPath: path))
    }

    /// A policy for the test's Firefox in the person's macOS preferences, as `defaults write` sets one; nil removes it.
    private func setPreference(_ key: String, _ value: CFPropertyList?) {
        let domain = self.domain as CFString
        CFPreferencesSetValue(key as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
