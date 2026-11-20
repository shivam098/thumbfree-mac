import AppKit
import ThumbFreeCore

/// Which browser windows History leaves out (PLAN 3.8): private windows, as thumbfree-windows `FocusInspector` tells
/// them from their titles, and, on the Mac, any browser window that can't be told apart from one. The title is the
/// window's AXTitle, from the box's read (`FocusedField.windowTitle`); a browser window whose box or title can't be
/// read counts as private. Samples are never kept from browsers at all (`SampleStore`). What the browsers' sources
/// say:
///
/// - Chrome, Chromium and Brave: the AXTitle is the window's accessible title (Chromium's
///   `NativeWidgetMacNSWindow.accessibilityTitle`, from `BrowserView::GetAccessibleWindowTitle`), "<page> - Google
///   Chrome", with " (Incognito)", " (Guest)" or " (Isolated)" added for a window that keeps no history (Brave:
///   " (Private)", its Tor windows too), in the browser's language. A title without the browser's name is a dialog's
///   or an app's, so it can't tell.
/// - Firefox, its Developer Edition and Nightly: " — Private Browsing" on macOS (`getWindowTitleForBrowser` in
///   Tabbrowser.sys.mjs), in its language, but nothing in permanent private browsing, which "Never remember history"
///   turns on (`browser.privatebrowsing.autostart` in a profile's prefs.js), and so can its administrator, where the
///   profiles never say so (`firefoxForcedPrivate`).
/// - Tor Browser and Mullvad Browser: always private.
/// - Safari: its private windows have the same titles as the others, and no other signal is known to be reliable (its
///   Window menu's "Move Tab to New Private Window" is right only for the window in front, once Safari has updated the
///   menu), so its dictations aren't kept, nor those of any other browser (Edge, Arc, Opera, Vivaldi…).
public enum PrivateWindows {
    /// Why a dictation isn't kept in History, for the log (which never has the title).
    public enum Reason: String, Sendable {
        /// The window's title says it's private.
        case privateWindow = "private"
        /// The browser's windows are all private.
        case alwaysPrivate = "private-always"
        /// The window's title couldn't be read.
        case noTitle = "private-no-title"
        /// The title can't tell: the browser's private windows look like its others, or it isn't a title the browser
        /// makes for its windows.
        case cantTell = "private-unknown"
    }

    /// How a browser's private windows are told apart.
    enum Rule: Equatable, Sendable {
        /// Chromium's accessible window title, which names the browser: `brands` are the ways its languages write it.
        case chromium(brands: [String])
        case firefox
        case alwaysPrivate
        /// No reliable way is known.
        case unknown
    }

    /// The browsers whose private windows can be told apart, by bundle identifier, lowercased as `Browsers` keeps them;
    /// a channel adds to one after a dot ("com.google.chrome.beta"). Every other browser is `.unknown`.
    static let rules: [(bundle: String, rule: Rule)] = [
        // "Google Chrome", with Beta, Dev or Canary after it; "Chrome" in Korean, "Google Chroma" in Slovenian.
        ("com.google.chrome", .chromium(brands: ["Chrom"])),
        // "क्रोमियम" in Hindi and Nepali.
        ("org.chromium.chromium", .chromium(brands: ["Chromium", "क्रोमियम"])),
        ("com.brave.browser", .chromium(brands: ["Brave"])),
        ("org.mozilla.firefox", .firefox),
        ("org.mozilla.firefoxdeveloperedition", .firefox),
        ("org.mozilla.nightly", .firefox),
        ("org.torproject.torbrowser", .alwaysPrivate),
        ("net.mullvad.mullvadbrowser", .alwaysPrivate),
    ]

    /// Firefox's folder, where profiles.ini and Profiles are (tests: a folder of their own).
    static let firefoxFolder = LockedValue(
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Library/Application Support/Firefox"))

    /// Where a Firefox is installed, by its bundle identifier: each copy running, and the one macOS opens (tests: apps
    /// of their own).
    static let firefoxApps = LockedValue<(String) -> [String]>({ bundleIdentifier in
        var apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .compactMap { $0.bundleURL?.path }
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path,
           !apps.contains(installed) {
            apps.append(installed)
        }

        return apps
    })

    /// The macOS preferences domain a Firefox reads its policies from: its bundle identifier (tests: one of their own).
    static let firefoxPolicyDomain = LockedValue<(String) -> String>({ $0 })

    /// What each file read for Firefox said, by what it was read for and its path, with its modification date and
    /// size: it's read again only when they change.
    private static let verdicts = LockedValue<[String: (modified: Date, size: Int, verdict: Any)]>([:])

    /// A dictation into `app`'s window titled `title` (nil: it couldn't be read) isn't kept in History. Never for an
    /// app that isn't a browser. Reads Firefox's profiles, so call it off the main thread.
    public static func mayBePrivate(_ app: TargetApp, title: String?) -> Bool {
        reason(app, title: title) != nil
    }

    /// Why a dictation into `app`'s window titled `title` isn't kept in History; nil when it is.
    public static func reason(_ app: TargetApp, title: String?) -> Reason? {
        guard Browsers.isBrowser(app.bundleIdentifier) else { return nil }
        switch rule(app.bundleIdentifier) {
        case .alwaysPrivate:
            return .alwaysPrivate
        case .unknown:
            return .cantTell
        case .chromium(let brands):
            guard let title = readable(title) else { return .noTitle }
            if chromiumMarkers.contains(where: { title.contains($0) }) {
                return .privateWindow
            }

            return brands.contains(where: { title.contains($0) }) ? nil : .cantTell
        case .firefox:
            guard let title = readable(title) else { return .noTitle }
            if firefoxMarkers.contains(where: { title.contains($0) }) {
                return .privateWindow
            }

            return firefoxNeverRemembers() || firefoxForcedPrivate(app.bundleIdentifier) ? .alwaysPrivate : nil
        }
    }

    static func rule(_ bundleIdentifier: String?) -> Rule {
        guard let id = bundleIdentifier.map({ DotNet.trim($0).lowercased() }), !id.isEmpty else { return .unknown }
        return rules.first { id == $0.bundle || id.hasPrefix($0.bundle + ".") }?.rule ?? .unknown
    }

    private static func readable(_ title: String?) -> String? {
        guard let title, !DotNet.isNullOrWhiteSpace(title) else { return nil }
        return title
    }

    /// Firefox set to never remember history (Settings › Privacy & Security), which makes its windows private without
    /// a word in their titles: `browser.privatebrowsing.autostart` in any of its profiles' prefs.js (the profiles in
    /// profiles.ini and every folder in Profiles). A prefs.js that's there but can't be read counts as saying so.
    static func firefoxNeverRemembers() -> Bool {
        let folder = firefoxFolder.value as NSString
        var profiles: Set<String> = []
        let ini = (try? String(contentsOfFile: folder.appendingPathComponent("profiles.ini"), encoding: .utf8)) ?? ""
        for line in ini.split(whereSeparator: \.isNewline) {
            let entry = DotNet.trim(String(line))
            guard entry.hasPrefix("Path=") else { continue }
            let path = String(entry.dropFirst("Path=".count))
            profiles.insert(path.hasPrefix("/") ? path : folder.appendingPathComponent(path))
        }

        let all = folder.appendingPathComponent("Profiles") as NSString
        for name in (try? FileManager.default.contentsOfDirectory(atPath: all as String)) ?? [] {
            profiles.insert(all.appendingPathComponent(name))
        }

        return profiles.contains { neverRemembers(($0 as NSString).appendingPathComponent("prefs.js")) }
    }

    private static func neverRemembers(_ prefs: String) -> Bool {
        let verdict = read(prefs, for: "prefs") { (data: Data) -> Bool in
            String(decoding: data, as: UTF8.self).range(
                of: #"user_pref\("browser\.privatebrowsing\.autostart",\s*true\);"#, options: .regularExpression) != nil
        }

        switch verdict {
        case .missing: return false
        case .unreadable: return true
        case .judged(let never): return never
        }
    }

    /// Firefox made private by its administrator, which its profiles never show: an enterprise policy, in the app's
    /// distribution/policies.json (`policiesFileForcesPrivate`) or in macOS preferences for its bundle identifier
    /// (`preferencesForcePrivate`), or AutoConfig (`autoConfigForcesPrivate`). Both set
    /// browser.privatebrowsing.autostart on Firefox's default branch, which prefs.js doesn't have.
    static func firefoxForcedPrivate(_ bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier.map({ DotNet.trim($0) }), !id.isEmpty else { return false }
        if preferencesForcePrivate(firefoxPolicyDomain.value(id)) {
            return true
        }

        return firefoxApps.value(id).contains { app in
            let resources = (app as NSString).appendingPathComponent("Contents/Resources")
            let policies = (resources as NSString).appendingPathComponent("distribution/policies.json")
            return policiesFileForcesPrivate(policies) || autoConfigForcesPrivate(resources)
        }
    }

    /// The preference that makes every window private.
    private static let autostart = "browser.privatebrowsing.autostart"

    /// Firefox's enterprise policies that make every window private (Policies.sys.mjs): PrivateBrowsingModeAvailability
    /// 2, or the Preferences policy setting browser.privatebrowsing.autostart to true, alone or as its Value with any
    /// Status but "clear". macOS preferences may have true as 1.
    static func policiesForcePrivate(_ policies: [String: Any]) -> Bool {
        if number(policies["PrivateBrowsingModeAvailability"]) == 2 {
            return true
        }

        guard let preferences = policies["Preferences"] as? [String: Any], let setting = preferences[autostart] else {
            return false
        }

        if let setting = setting as? [String: Any] {
            return (setting["Status"] as? String) != "clear" && isTrue(setting["Value"])
        }

        return isTrue(setting)
    }

    /// A Firefox's distribution/policies.json (JSONPoliciesProvider), judged by `policiesForcePrivate`. One that's
    /// there but can't be read or parsed counts as making it private.
    private static func policiesFileForcesPrivate(_ path: String) -> Bool {
        let verdict = read(path, for: "policies") { (data: Data) -> Bool in
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
            return policiesForcePrivate(json["policies"] as? [String: Any] ?? [:])
        }

        switch verdict {
        case .missing: return false
        case .unreadable: return true
        case .judged(let forced): return forced
        }
    }

    /// Firefox's policies in macOS preferences for `domain` (nsMacPreferencesReader): configuration profiles,
    /// /Library/Preferences and the person's own, which count once EnterprisePoliciesEnabled is true in one. Each is
    /// judged on its own, and the Preferences policy may be flat, with "__" between its levels (macOSPoliciesParser).
    static func preferencesForcePrivate(_ domain: String) -> Bool {
        let domain = domain as CFString
        // nil: the value in force, a configuration profile's first.
        let sources: [(user: CFString, host: CFString)?] = [
            nil, (kCFPreferencesAnyUser, kCFPreferencesAnyHost), (kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            (kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
        ]
        func value(_ key: String, _ source: (user: CFString, host: CFString)?) -> Any? {
            guard let source else { return CFPreferencesCopyAppValue(key as CFString, domain) }
            return CFPreferencesCopyValue(key as CFString, domain, source.user, source.host)
        }

        guard sources.contains(where: { isTrue(value("EnterprisePoliciesEnabled", $0)) }) else { return false }
        let flat = "Preferences__" + autostart
        return sources.contains { source in
            var policies: [String: Any] = [:]
            policies["PrivateBrowsingModeAvailability"] = value("PrivateBrowsingModeAvailability", source)
            policies["Preferences"] = value("Preferences", source)
            if policiesForcePrivate(policies) {
                return true
            }

            var setting: [String: Any] = [:]
            setting["Value"] = value(flat + "__Value", source)
            setting["Status"] = value(flat + "__Status", source)
            var flatSetting: Any? = value(flat, source)
            if flatSetting == nil && !setting.isEmpty {
                flatSetting = setting
            }

            guard let flatSetting else { return false }
            return policiesForcePrivate(["Preferences": [autostart: flatSetting]])
        }
    }

    /// What a Firefox's defaults/pref files say about AutoConfig: the .cfg file's name, and how its bytes are shifted.
    private struct AutoConfig {
        var fileName: String?
        var obscureValue: Int?
    }

    /// AutoConfig (nsReadConfig.cpp): `general.config.filename` in the app's defaults/pref files names a .cfg file in
    /// Resources, its bytes shifted by `general.config.obscure_value` (13 unless they say otherwise), that sets
    /// browser.privatebrowsing.autostart to true. One that's there but can't be read, or that loads more from a server
    /// (`autoadmin.global_config_url`), counts as setting it.
    private static func autoConfigForcesPrivate(_ resources: String) -> Bool {
        let defaults = (resources as NSString).appendingPathComponent("defaults/pref") as NSString
        var config = AutoConfig()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: defaults as String)) ?? []
        for name in names.sorted() where name.hasSuffix(".js") {
            if case .judged(let found) = read(defaults.appendingPathComponent(name), for: "defaults", autoConfig(in:)) {
                config.fileName = found.fileName ?? config.fileName
                config.obscureValue = found.obscureValue ?? config.obscureValue
            }
        }

        // Firefox skips dsengine.cfg, a known bad one.
        guard let fileName = config.fileName, !fileName.isEmpty, fileName != "dsengine.cfg" else { return false }
        let obscure = config.obscureValue ?? 13
        let cfg = (resources as NSString).appendingPathComponent(fileName)
        let verdict = read(cfg, for: "cfg \(obscure)") { (data: Data) -> Bool in setsPrivateBrowsing(data, obscure) }
        switch verdict {
        case .missing: return false
        case .unreadable: return true
        case .judged(let sets): return sets
        }
    }

    private static func autoConfig(in data: Data) -> AutoConfig {
        let text = String(decoding: data, as: UTF8.self)
        return AutoConfig(
            fileName: lastMatch(#"pref\s*\(\s*["']general\.config\.filename["']\s*,\s*["']([^"']*)["']"#, in: text),
            obscureValue: lastMatch(#"pref\s*\(\s*["']general\.config\.obscure_value["']\s*,\s*(-?\d+)"#, in: text)
                .flatMap { Int($0) })
    }

    /// The .cfg, its bytes shifted back as Firefox does, sets browser.privatebrowsing.autostart to true (with pref,
    /// defaultPref, lockPref or a branch's setBoolPref), or loads more from a server.
    private static func setsPrivateBrowsing(_ data: Data, _ obscure: Int) -> Bool {
        let shift = UInt8(truncatingIfNeeded: obscure)
        let text = String(decoding: obscure > 0 ? data.map { $0 &- shift } : Array(data), as: UTF8.self)
        return text.range(of: #"["']browser\.privatebrowsing\.autostart["']\s*,\s*true\b"#, options: .regularExpression)
            != nil || text.contains("autoadmin.global_config_url")
    }

    private static func lastMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// As Firefox reads a yes in macOS preferences: true, a number but 0, or "yes", "true" or "1".
    private static func isTrue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }

        guard let text = value as? String else { return false }
        return ["yes", "true", "1"].contains(DotNet.trim(text).lowercased())
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        return (value as? String).flatMap { Int(DotNet.trim($0)) }
    }

    /// A file as `judge` found it, or why there was nothing to judge.
    private enum FileVerdict<Verdict> {
        case missing
        /// It's there, but can't be read.
        case unreadable
        case judged(Verdict)
    }

    /// `judge`'s verdict on the file at `path`, kept (with what it was read `for`) until the file's modification date
    /// or size changes.
    private static func read<Verdict>(
        _ path: String, for purpose: String, _ judge: (Data) -> Verdict
    ) -> FileVerdict<Verdict> {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: path) else {
            return files.fileExists(atPath: path) ? .unreadable : .missing
        }

        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let key = purpose + "\u{0}" + path
        if let known = verdicts.value[key], known.modified == modified, known.size == size,
           let verdict = known.verdict as? Verdict {
            return .judged(verdict)
        }

        guard let data = files.contents(atPath: path) else { return .unreadable }
        let verdict = judge(data)
        verdicts.update { $0[key] = (modified: modified, size: size, verdict: verdict) }
        return .judged(verdict)
    }
}

extension PrivateWindows {
    /// What Chromium and Brave add to the accessible title of a window that keeps no history, in every language they
    /// ship: Chromium's IDS_ACCESSIBLE_INCOGNITO_WINDOW_TITLE_FORMAT, IDS_ACCESSIBLE_GUEST_WINDOW_TITLE_FORMAT and
    /// IDS_ACCESSIBLE_ISOLATED_WINDOW_TITLE_FORMAT (chrome/app/resources/generated_resources_*.xtb, translations
    /// 6751344591405861699, 1572139610531470719 and 879230900046110068), and Brave's own for its private windows
    /// (brave-core app/resources/generated_resources_*.xtb, 6827869674836193263), without the window title. November
    /// 2026; the text matches anywhere in the title, as Mongolian puts the guest one first.
    static let chromiumMarkers: [String] = [
        "(Anhysbys)", "(Anonimno)", "(Anonymní režim)", "(Bisita)", "(Ezkutua)", "(Faragha)", "(Gas)", "(Gast)",
        "(Geïsoleer)", "(Gizli mod)", "(Gizli)", "(Gost)", "(Guest)", "(Gwestai)", "(Hali fiche)", "(Huru)",
        "(I izoluar)", "(In incognito)", "(Incognito)", "(Incògnit)", "(Incógnito)", "(Inkognito režīms)",
        "(Inkognito)", "(Inkognitó mód)", "(Inkoqnito)", "(Isihambeli)", "(Isolated)", "(Isolé)", "(Izolyatsiyalangan)",
        "(Khách)", "(Kişisel)", "(Külaline)", "(Maxfiy)", "(Mehmon)", "(Mgeni)", "(Misafir)", "(Modo anônimo)",
        "(Navegação anónima)", "(Navegação privada)", "(Navigation privée)", "(Okuhlukanisiwe)", "(Ospite)",
        "(Pribadi)", "(Pribado)", "(Privado)", "(Privat)", "(Private)", "(Privatno)", "(Privato)", "(Privát)",
        "(Privé)", "(Prywatny)", "(Qonaq)", "(Riêng tư)", "(Samaran)", "(Soukomé)", "(Sulit)", "(Súkromný)", "(Tamu)",
        "(Terasing)", "(Terisolasi)", "(Tetamu)", "(Tách biệt)", "(Yalıtılmış)", "(Yksityinen)", "(Ynysig)",
        "(aislada)", "(aislado)", "(anonimni način)", "(anonimno)", "(anonym)", "(aïllada)", "(bez arhiviranja)",
        "(brez beleženja zgodovine)", "(convidado)", "(convidat)", "(e fshehtë)", "(einangrað)", "(eristetty)",
        "(ezkutuko moduan)", "(gast)", "(gestur)", "(geïsoleerd)", "(gjest)", "(gonbidatua)", "(gost)", "(gość)",
        "(gäst)", "(gæst)", "(host)", "(hosť)", "(huliðsgluggi)", "(i-Incognito)", "(illado)", "(incógnito)",
        "(inkognito)", "(invitado)", "(invitat)", "(invité)", "(isolado)", "(isolata)", "(isolatuta)", "(isoleeritud)",
        "(isolerat)", "(isoleret)", "(isolert)", "(isoliert)", "(isolé)", "(izolată)", "(izolirani način)",
        "(izolirano)", "(izoliuota)", "(izolovano)", "(izolované)", "(izolováno)", "(izolált)", "(izolēts)",
        "(modo de convidado)", "(modo isolado)", "(privaatne)", "(privatno)", "(svečias)",
        "(tryb przeglądania prywatnego)", "(vendég)", "(vieras)", "(viesa režīms)", "(visitante)", "(vizitor)",
        "(İzolə edilmiş)", "(Ανώνυμη περιήγηση)", "(Απομονωμένο)", "(Επισκέπτης)", "(Ιδιωτικό)", "(Анонімний перегляд)",
        "(Гостин)", "(Госць)", "(Жашыруун)", "(Жеке)", "(Зочин)", "(Изолиран режим)", "(Инкогнито)", "(Конок)",
        "(Нууцлал)", "(Нууцлалтай)", "(Окчундатылган)", "(Поверителен)", "(Приватне)", "(Приватно)", "(Приватное)",
        "(без архивирања)", "(гост)", "(гость)", "(гість)", "(изолиран режим)", "(изолировано)", "(изоловано)",
        "(инкогнито)", "(оқшау)", "(тусгаарласан)", "(ізаляваны рэжым)", "(ізольовано)", "(інкогніта)", "(қонақ)",
        "(ինկոգնիտո)", "(հյուր)", "(մեկուսացված)", "(אורח)", "(גלישה בסתר)", "(מבודד)", "(التصفح المتخفي)",
        "(الگ تھلگ)", "(خاص)", "(خصوصی)", "(مجزا)", "(مهمان)", "(مہمان)", "(ناشناس)", "(نافذة تصفّح معزول)",
        "(وضع الضيف)", "(پوشیدگی)", "(अतिथि)", "(अतिथी)", "(अलिप्त)", "(आइसोलेटेड)", "(गुप्त)", "(निजी)", "(प्राइवेट)",
        "(मेहमान)", "(অতিথি)", "(আইচ’লেটেড)", "(আইসোলেটেড)", "(ইনক’গনিট’)", "(ছদ্মবেশী)", "(ਆਇਸੋਲੇਟਿਡ)", "(ਗੁਮਨਾਮ)",
        "(ਪ੍ਰਾਈਵੇਟ)", "(ਮਹਿਮਾਨ)", "(અતિથિ)", "(આઇસોલેટેડ)", "(ખાનગી)", "(છૂપી)", "(ଅତିଥି)", "(ଆଇସୋଲେଟେଡ)", "(ଇନ୍‌କଗ୍ନିଟୋ)",
        "(ஐசோலேட்டட்)", "(கெஸ்ட்)", "(மறைநிலை)", "(అజ్ఞాతంగా)", "(ఐసోలేటెడ్)", "(గెస్ట్)", "(ಅತಿಥಿ)", "(ಅದೃಶ್ಯ)", "(ಐಸೋಲೆಟೆಡ್)", "(ಖಾಸಗಿ)",
        "(അതിഥി)", "(ആള്‍മാറാട്ടം)", "(ഐസൊലേറ്റഡ്)", "(අමුත්තා)", "(පෞද්ගලික)", "(හුදකලා කළ)", "(ผู้มาเยือน)", "(ส่วนตัว)", "(แยก)",
        "(โหมดไม่ระบุตัวตน)", "(ບໍ່ເປີດເຜີຍຕົນຕົວ)", "(ແຂກ)", "(ແຍກ)", "(ရုပ်ဖျက်)", "(သီးခြားခွဲထားသည်)", "(ဧည့်သည်)", "(იზოლირებული)",
        "(ინკოგნიტო)", "(პირადი)", "(სტუმარი)", "(ማንነትን የማያሳውቅ)", "(ተገልሏል)", "(እንግዳ)", "(የግል)", "(ដាច់ដោយឡែក)", "(ភ្ញៀវ)",
        "(អនាមិក)", "(ឯកជន)", "(Ẩn danh)", "(プライベート)", "(已隔離)", "(無痕模式)", "(訪客)", "(隔離)", "(게스트)",
        "(분리됨)", "(시크릿 모드)", "(시크릿)", "（アイソレート）", "（ゲスト）", "（シークレット モード）",
        "（无痕）", "（访客）", "（隔离）",
    ]

    /// What Firefox on macOS adds to a private window's title, in every language it ships: browser.ftl's
    /// browser-main-private-suffix-for-content and the macOS browser-main-private-window-title without the brand
    /// (mozilla-firefox/firefox for en-US, mozilla-l10n/firefox-l10n for the others), where one isn't covered by a
    /// shorter one. November 2026.
    static let firefoxMarkers: [String] = [
        "Anonymní prohlížení", "Brabhsadh prìobhaideach", "Duyệt web riêng tư", "Gizli Gezinti", "Huliðsvafur",
        "Ichinan okem pa k'amaya'l", "Kundaha ñemi", "Meramban Privat", "Merdeiñ prevez", "Modus privat",
        "Məxfi Səyahət", "Nabigatze Pribatua", "Nabigatze pribatua", "Navegacion privada", "Navegació privada",
        "Navegación Privada", "Navegación privada", "Navegaçion Privâ", "Navegação privada", "Navegação privativa",
        "Navigare privată", "Navigation private", "Navigation privée", "Navigatzione privada", "Navigazion privade",
        "Navigazione anonima", "Pelayaran Peribadi", "Penjelajahan Pribadi", "Pori Preifat",
        "Privaatne veebilehitsemine", "Privat browsing", "Privat nettlesing", "Privat surfning", "Privata retumo",
        "Private Browsing", "Privater Modus", "Privatno pregledavanje", "Privatno pretraživanje", "Priveenavigaasje",
        "Privát böngészés", "Privénavigatie", "Privātā pārlūkošana", "Priwatny modus", "Shfletim Privat",
        "Súkromné prehliadanie", "Tryb prywatny", "Tunigin tusligt", "Yksityinen selaus", "Zasebno brskanje",
        "huliðsvafur", "navegação privativa", "privatno pregledanje", "privatno pregledavanje", "privát böngészés",
        "privénavigatie", "privātā pārlūkošana", "tryb prywatny", "Ιδιωτική περιήγηση", "Жекелік шолу",
        "Поверително сърфиране", "Приватний перегляд", "Приватный просмотр", "Прыватнае агляданне", "Тамошобинии махфӣ",
        "Тамошобинии хусусӣ", "приватно прегледање", "Գաղտնի դիտարկում", "գաղտնի դիտարկում", "גלישה פרטית",
        "التصفح الخاص", "مرور ناشناس", "نجی براؤزنگ", "گشتن سیخومی", "ব্যক্তিগত ব্রাউজিং", "ਪ੍ਰਾਈਵੇਟ ਬਰਾਊਜ਼ਿੰਗ",
        "అంతరంగిక విహరణ", "ఆంతరంగిక విహారణ", "സ്വകാര്യ തിരച്ചിൽ", "การท่องเว็บแบบส่วนตัว", "การเรียกดูแบบส่วนตัว", "ການທ່ອງເວັບແບບສ່ວນຕົວ",
        "პირადი თვალიერება", "ᱯᱨᱟᱭᱣᱮᱴ ᱵᱽᱨᱟᱣᱩᱡᱤᱝ", "プライベートブラウジング", "隐私浏览", "隱私瀏覽模式",
        "사생활 보호 모드",
    ]
}
