import AppKit
import ThumbFreeCore

/// Web browsers, by bundle identifier (thumbfree-windows `Browsers`, which goes by process name). A browser can't
/// reliably say whether a window is private: Chrome's and Brave's private windows have no marker in their titles, and
/// other browsers translate theirs. So whatever goes into a browser is treated as possibly private (PLAN 3.8: where
/// privacy is unknown, keep no samples). Besides the browsers listed here, every app on this Mac that opens web links
/// counts (`BrowserList`), as on Windows every browser registered on the PC does.
public enum Browsers {
    private static let state = State()

    /// True for a browser's bundle identifier ("com.google.Chrome"), in any case. Empty is no app, not a browser.
    public static func isBrowser(_ bundleIdentifier: String?) -> Bool { state.list.isBrowser(bundleIdentifier) }

    /// Reads the apps that open web links in the background (at start), so no dictation waits for it.
    public static func prepare() { state.list.prepare() }

    /// Tests: the apps that open web links come from `read` instead of this Mac's Launch Services.
    static func readRegistered(from read: @escaping () throws -> [String]) {
        state.list = BrowserList(readRegistered: read)
    }

    /// The bundle identifiers of the apps that can open https links here (Launch Services), browsers among them.
    static func appsOpeningWebLinks() -> [String] {
        guard let link = URL(string: "https://example.com") else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: link).compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// The list in use, behind a lock.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var current = BrowserList(readRegistered: Browsers.appsOpeningWebLinks)

        var list: BrowserList {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }
}

/// The known browsers plus the apps that open web links on this Mac, read once (in the background) and kept. Reading
/// them never throws and never holds a dictation up for more than `wait`: until they're read, only the known ones
/// count.
final class BrowserList: @unchecked Sendable {
    /// Chromium's, Firefox's (and the browsers built on it) and Safari's. Channels add to them after a dot
    /// ("com.google.Chrome.canary"). Tor Browser and Mullvad Browser are Firefox underneath.
    static let known: [String] = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "ai.perplexity.comet", "ru.yandex.desktop.yandex-browser", "com.naver.Whale", "net.imput.helium",
        "org.ecosia.browser", "com.duckduckgo.macos.browser", "com.kagi.kagimacOS",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "org.torproject.torbrowser", "net.mullvad.mullvadbrowser", "io.gitlab.librewolf-community",
        "net.waterfox.waterfox", "one.ablaze.floorp",
    ].map { $0.lowercased() }

    private let readRegistered: () throws -> [String]
    private let wait: TimeInterval
    private let lock = NSLock()
    private let read = DispatchGroup()
    private var started = false
    private var registered: Set<String> = []

    /// - Parameter wait: The longest `isBrowser` waits for the apps that open web links to be read.
    init(readRegistered: @escaping () throws -> [String], wait: TimeInterval = 0.25) {
        self.readRegistered = readRegistered
        self.wait = wait
    }

    /// True for a browser's bundle identifier; case doesn't matter. Empty is no app, not a browser.
    func isBrowser(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier.map({ DotNet.trim($0).lowercased() }), !identifier.isEmpty else {
            return false
        }

        if Self.known.contains(where: { identifier == $0 || identifier.hasPrefix($0 + ".") }) {
            return true
        }

        prepare()
        return read.wait(timeout: .now() + wait) == .success && lock.withLock { registered.contains(identifier) }
    }

    /// Starts reading the apps that open web links, if that hasn't started yet.
    func prepare() {
        let start: Bool = lock.withLock {
            if started {
                return false
            }

            started = true
            read.enter()
            return true
        }

        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            var names: Set<String> = []
            do {
                for name in try readRegistered() where !DotNet.isNullOrWhiteSpace(name) {
                    names.insert(DotNet.trim(name).lowercased())
                }
            } catch {
                // Without them, the known browsers still count.
                Log.warn("couldn't read the apps that open web links: \(Log.kind(of: error))")
            }

            lock.withLock { registered = names }
            read.leave()
        }
    }
}
