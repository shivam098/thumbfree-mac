import Foundation
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
///   turns on (`browser.privatebrowsing.autostart` in a profile's prefs.js).
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

    /// What each prefs.js said, by path, with its modification date: it's read again only when it changes.
    private static let prefsRead = LockedValue<[String: (modified: Date, neverRemembers: Bool)]>([:])

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

            return firefoxNeverRemembers() ? .alwaysPrivate : nil
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
    /// profiles.ini and every folder in Profiles).
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
        let attributes = try? FileManager.default.attributesOfItem(atPath: prefs)
        guard let modified = attributes?[.modificationDate] as? Date else { return false }

        if let known = prefsRead.value[prefs], known.modified == modified {
            return known.neverRemembers
        }

        let text = (try? String(contentsOfFile: prefs, encoding: .utf8)) ?? ""
        let never = text.range(
            of: #"user_pref\("browser\.privatebrowsing\.autostart",\s*true\);"#, options: .regularExpression) != nil
        prefsRead.update { $0[prefs] = (modified: modified, neverRemembers: never) }
        return never
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
