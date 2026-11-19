import ApplicationServices
import Foundation

/// The text box a dictation is for, read with the Accessibility API once when it starts (docs/mac.md, "Typing into
/// other apps"): what kind of box it is, the text before the cursor, the app and window it's in, and how to recognise
/// it again, so text only ever goes into that same box. The Mac side of thumbfree-windows `FocusedField` and
/// `FocusInspector`. These are the facts only: the rules that use them (which apps and pages get email layout,
/// private windows, what History keeps) are the core's. Nothing read here is logged or kept.
public struct FocusedField: Sendable {
    /// The app the box is in.
    public struct App: Equatable, Sendable {
        public var processIdentifier: pid_t
        public var bundleIdentifier: String?
        public var name: String?
        /// Built with Electron (Slack, VS Code, Discord…), whose pages are described only once asked: see
        /// `Reader.wakesWebContent`.
        public var isElectron: Bool

        public init(
            processIdentifier: pid_t, bundleIdentifier: String? = nil, name: String? = nil, isElectron: Bool = false
        ) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.isElectron = isElectron
        }
    }

    /// An element of another app's interface: an AXUIElement (a plain object in tests). Elements can be used from any
    /// thread.
    public struct Element: @unchecked Sendable {
        let object: AnyObject

        init(_ object: AnyObject) {
            self.object = object
        }
    }

    /// Accessibility couldn't answer: it's off for ThumbFree, the element has gone, or the app didn't answer in time.
    public struct NoAnswer: Error {
        public init() {}
    }

    /// How `Reader.isSameField` recognises the box again: the element itself, or, while a web app's box couldn't be
    /// found (its focus was on the page or the window), the page or window it's in, as on Windows.
    enum Identity {
        case box(Element)
        case page(Element)
        case window(Element)
        case app
    }

    public let app: App
    /// The title of the window the box is in: the page's title in a browser.
    public let windowTitle: String?
    /// That window's frame, in Accessibility coordinates (from the top left of the main display, y down).
    public let windowFrame: CGRect?
    /// kAXRoleAttribute: AXTextField, AXTextArea, AXComboBox… (nil when the app doesn't say).
    public let role: String?
    /// kAXSubroleAttribute: AXSecureTextField, AXSearchField…
    public let subrole: String?
    /// A password box (AXSecureTextField): never typed into, and its text is never read.
    public let isSecure: Bool
    /// A search or address box: AXSearchField, or a label or identifier that says "search" (as on Windows, where the
    /// element's name or automation id is checked). Browsers' address bars say so in their labels.
    public let isSearch: Bool
    /// Inside a web page (an AXWebArea): in a browser, an Electron app or a web view.
    public let isInWebPage: Bool
    /// True or false when the box says so (AXTextArea takes line breaks; text fields, combo boxes, search and password
    /// boxes don't); nil when it doesn't, as on Windows, where such boxes are treated as taking them.
    public let takesLineBreaks: Bool?
    /// The text before the cursor, at most the last `Reader.maxTextBefore` UTF-16 units; nil when the box doesn't say.
    public let textBefore: String?
    /// False when only the whole value could be read: the cursor is then taken to be at its end.
    public let caretKnown: Bool
    /// IsSecureEventInputEnabled(): a password is being typed somewhere, so nothing may be typed.
    public let secureEventInput: Bool
    let identity: Identity

    /// For logs: the kind of box, never its text or title ("AXTextArea multi-line web").
    public var kind: String {
        var kind = role ?? "no role"
        if let subrole { kind += "/" + subrole }
        if let takesLineBreaks { kind += takesLineBreaks ? " multi-line" : " single-line" }
        if isSearch { kind += " search" }
        if isSecure { kind += " secure" }
        if isInWebPage { kind += " web" }
        if !isBox { kind += " unresolved" }
        if secureEventInput { kind += " secure-input" }
        return kind
    }

    /// The focus was on the box itself, not on a web page still describing itself.
    var isBox: Bool {
        if case .box = identity { return true }
        return false
    }
}

extension FocusedField {
    /// The Accessibility calls the reader makes, behind a protocol so the reading can be tested without other apps
    /// (FakeAXSystem in the tests). Elements are AXUIElements in the system's version. A missing attribute is nil; a
    /// call that gets no answer throws `NoAnswer`.
    public protocol Accessibility: AnyObject {
        /// The element with the keyboard focus, in whichever app has it (kAXFocusedUIElementAttribute, system-wide).
        func focusedElement() throws -> AnyObject?
        func string(_ attribute: String, of element: AnyObject) throws -> String?
        /// A range attribute, such as kAXSelectedTextRangeAttribute: in UTF-16 units, as NSString counts.
        func range(_ attribute: String, of element: AnyObject) throws -> CFRange?
        func element(_ attribute: String, of element: AnyObject) throws -> AnyObject?
        /// kAXPositionAttribute and kAXSizeAttribute together.
        func frame(of element: AnyObject) throws -> CGRect?
        func processIdentifier(of element: AnyObject) throws -> pid_t
        /// The app's own element (AXUIElementCreateApplication).
        func application(_ processIdentifier: pid_t) -> AnyObject
        /// Sets a true/false attribute; false when the app refused it.
        func setFlag(_ attribute: String, _ value: Bool, of element: AnyObject) -> Bool
        /// The same element (CFEqual).
        func isSame(_ element: AnyObject, as other: AnyObject) -> Bool
        func app(_ processIdentifier: pid_t) -> App
        /// IsSecureEventInputEnabled().
        var secureEventInput: Bool { get }
    }

    /// Reads the focused box when a dictation starts (`read`) and checks it again before each piece is typed
    /// (`isSameField`). Safe to use from any thread; its calls wait while the app answers, so keep it off the main
    /// thread.
    public final class Reader: @unchecked Sendable {
        /// The most text before the cursor that's kept, in UTF-16 units (C# chars on Windows).
        public static let maxTextBefore = 2000

        /// After a Chromium or Electron app is woken, how long the reader waits for its box to have the focus, and how
        /// often it looks (Windows: 1.2 s, every 50 ms).
        static let wakeWait: TimeInterval = 1.2
        static let wakePoll: TimeInterval = 0.05

        /// The most parents looked at for the page and the window around the box.
        static let maxDepth = 60

        /// Chromium browsers, by bundle identifier (betas and other channels add to it after a dot).
        static let chromiumBrowsers = [
            "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium",
            "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser",
        ]

        private let source: Accessibility
        private let sleep: (TimeInterval) -> Void
        private let now: () -> TimeInterval
        private let lock = NSLock()
        private var wakes = true
        private var woken: Set<String> = []

        /// Reads with the Accessibility API itself.
        public convenience init() {
            self.init(source: SystemAccessibility())
        }

        public init(
            source: Accessibility,
            sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.source = source
            self.sleep = sleep
            self.now = now
        }

        /// Chrome, Edge, Brave and the other Chromium browsers, and Electron apps, describe their pages only once an
        /// assistive app asks, the way VoiceOver does: the first read in such an app sets AXEnhancedUserInterface
        /// (Chromium) or AXManualAccessibility (Electron) on it, once while it runs. True by default; to be measured on
        /// a real Mac (docs/mac.md).
        public var wakesWebContent: Bool {
            get { lock.withLock { wakes } }
            set { lock.withLock { wakes = newValue } }
        }

        /// The box with the keyboard focus now, or nil when Accessibility can't tell (it's off for ThumbFree, or the
        /// app didn't answer in time), nothing has the focus, or the focus is in ThumbFree itself. The first read in a
        /// Chromium or Electron app can take up to 1.2 s longer (`wakesWebContent`).
        public func read() -> FocusedField? {
            var asking = Asking(source)
            guard let first = asking.ask({ try $0.focusedElement() }),
                  let pid = asking.ask({ try $0.processIdentifier(of: first) }),
                  pid != ProcessInfo.processInfo.processIdentifier else { return nil }

            let app = source.app(pid)
            let web = Self.webContent(of: app)
            var element = first
            var role = asking.ask { try $0.string(kAXRoleAttribute, of: first) }
            var subrole = asking.ask { try $0.string(kAXSubroleAttribute, of: first) }
            guard asking.answered else { return nil }

            if let web, wakesWebContent, firstRead(in: app) {
                _ = source.setFlag(web.wakeAttribute, true, of: source.application(pid))
                if !Self.isBox(role: role, subrole: subrole), let box = waitForBox(in: pid, &asking) {
                    (element, role, subrole) = box
                }
            }

            let secure = role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
            let (page, window) = containers(of: element, role: role, pid: pid, &asking)
            let title = window.flatMap { window in asking.ask { try $0.string(kAXTitleAttribute, of: window) } }
            let frame = window.flatMap { window in asking.ask { try $0.frame(of: window) } }
            let search = role == kAXSearchFieldSubrole || subrole == kAXSearchFieldSubrole
                || (!secure && saysSearch(element, &asking))
            let lines: Bool? = secure || search ? false : Self.takesLineBreaks(role: role)
            let (before, caretKnown) = secure ? (nil, false) : textBefore(element, &asking)

            let identity: Identity
            if Self.isBox(role: role, subrole: subrole) || web == nil {
                identity = .box(Element(element))
            } else if let page {
                identity = .page(Element(page))
            } else if let window {
                identity = .window(Element(window))
            } else {
                identity = .app
            }

            return FocusedField(
                app: app, windowTitle: title, windowFrame: frame, role: role, subrole: subrole, isSecure: secure,
                isSearch: search, isInWebPage: page != nil, takesLineBreaks: lines, textBefore: before,
                caretKnown: caretKnown, secureEventInput: source.secureEventInput, identity: identity)
        }

        /// True when the focus is still in `start`'s box (the same AXUIElement, CFEqual; while a web app's box couldn't
        /// be found, the same page or window), false when it's somewhere else, nil when Accessibility can't tell. Never
        /// wakes anything.
        public func isSameField(_ start: FocusedField) -> Bool? {
            var asking = Asking(source)
            guard let focused = asking.ask({ try $0.focusedElement() }) else { return asking.answered ? false : nil }
            guard let pid = asking.ask({ try $0.processIdentifier(of: focused) }) else { return nil }
            guard pid == start.app.processIdentifier else { return false }

            switch start.identity {
            case .box(let box):
                return source.isSame(focused, as: box.object)
            case .page(let page):
                let role = asking.ask { try $0.string(kAXRoleAttribute, of: focused) }
                let (pageNow, _) = containers(of: focused, role: role, pid: pid, &asking)
                guard asking.answered else { return nil }
                return pageNow.map { source.isSame($0, as: page.object) } ?? false
            case .window(let window):
                let role = asking.ask { try $0.string(kAXRoleAttribute, of: focused) }
                let (_, windowNow) = containers(of: focused, role: role, pid: pid, &asking)
                guard asking.answered else { return nil }
                return windowNow.map { source.isSame($0, as: window.object) } ?? false
            case .app:
                return true
            }
        }

        /// The first read in `app` since ThumbFree started; later reads there don't wake it again.
        private func firstRead(in app: App) -> Bool {
            let key = "\(app.processIdentifier) \(app.bundleIdentifier ?? "")"
            return lock.withLock { woken.insert(key).inserted }
        }

        /// After a wake: the focused element once it's a text box, looked for every 50 ms for up to 1.2 s.
        private func waitForBox(in pid: pid_t, _ asking: inout Asking) -> (AnyObject, String?, String?)? {
            let deadline = now() + Self.wakeWait
            while now() < deadline {
                sleep(Self.wakePoll)
                guard let focused = asking.ask({ try $0.focusedElement() }),
                      asking.ask({ try $0.processIdentifier(of: focused) }) == pid else { return nil }

                let role = asking.ask { try $0.string(kAXRoleAttribute, of: focused) }
                let subrole = asking.ask { try $0.string(kAXSubroleAttribute, of: focused) }
                if Self.isBox(role: role, subrole: subrole) {
                    return (focused, role, subrole)
                }
            }

            return nil
        }

        /// The web page around `element` (the nearest AXWebArea, itself included) and its window, from its parents.
        /// Without a window among them, the element's AXWindow, else the app's focused window.
        private func containers(of element: AnyObject, role: String?, pid: pid_t, _ asking: inout Asking)
            -> (page: AnyObject?, window: AnyObject?)
        {
            var page: AnyObject?
            var node: AnyObject? = element
            var nodeRole = role
            for depth in 0..<Self.maxDepth {
                guard let current = node else { break }
                if depth > 0 {
                    nodeRole = asking.ask { try $0.string(kAXRoleAttribute, of: current) }
                }

                if nodeRole == "AXWebArea", page == nil {
                    page = current
                } else if nodeRole == kAXWindowRole {
                    return (page, current)
                } else if nodeRole == kAXApplicationRole {
                    break
                }

                node = asking.ask { try $0.element(kAXParentAttribute, of: current) }
            }

            if let window = asking.ask({ try $0.element(kAXWindowAttribute, of: element) }) {
                return (page, window)
            }

            return (page, asking.ask { try $0.element(kAXFocusedWindowAttribute, of: $0.application(pid)) })
        }

        /// A label or identifier that says "search": its title, description or placeholder, or its identifier (the
        /// web page's id), as Windows checks the element's name and automation id.
        private func saysSearch(_ element: AnyObject, _ asking: inout Asking) -> Bool {
            let labels = [
                kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", "AXIdentifier", "AXDOMIdentifier",
            ]
            return labels.contains { attribute in
                let label = asking.ask { try $0.string(attribute, of: element) }
                return label?.range(of: "search", options: .caseInsensitive) != nil
            }
        }

        /// From kAXValueAttribute to kAXSelectedTextRangeAttribute's start (UTF-16 units); without a selected range,
        /// the whole value, the cursor taken to be at its end (Windows' ValuePattern fallback). The last
        /// `maxTextBefore` units at most.
        private func textBefore(_ element: AnyObject, _ asking: inout Asking) -> (String?, Bool) {
            guard let value = asking.ask({ try $0.string(kAXValueAttribute, of: element) }) else { return (nil, false) }
            let range = asking.ask { try $0.range(kAXSelectedTextRangeAttribute, of: element) }
            if let range, range.location >= 0 {
                return (Self.lastUnits(Self.firstUnits(value, range.location), Self.maxTextBefore), true)
            }

            return (Self.lastUnits(value, Self.maxTextBefore), false)
        }

        /// A text box's own role: what the focus is on once a web page describes itself.
        static func isBox(role: String?, subrole: String?) -> Bool {
            let roles = [
                kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSearchFieldSubrole, kAXSecureTextFieldSubrole,
            ]
            let subroles = [kAXSearchFieldSubrole, kAXSecureTextFieldSubrole]
            return roles.contains { $0 == role } || subroles.contains { $0 == subrole }
        }

        /// AXTextArea takes line breaks, a text field or a combo box doesn't; other roles don't say.
        static func takesLineBreaks(role: String?) -> Bool? {
            if role == kAXTextAreaRole { return true }
            if role == kAXTextFieldRole || role == kAXComboBoxRole { return false }
            return nil
        }

        static func webContent(of app: App) -> WebContent? {
            if let id = app.bundleIdentifier, chromiumBrowsers.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) {
                return .chromium
            }

            return app.isElectron ? .electron : nil
        }

        /// The first `count` UTF-16 units of `text`, never half of a character made of two (a surrogate pair, as in
        /// most emoji): a count inside one stops before it. Swift strings can't hold half a character, where C# can.
        static func firstUnits(_ text: String, _ count: Int) -> String {
            let units = text.utf16
            var end = units.index(units.startIndex, offsetBy: min(max(count, 0), units.count))
            while end > units.startIndex, end.samePosition(in: text.unicodeScalars) == nil {
                end = units.index(before: end)
            }

            return String(String.UnicodeScalarView(text.unicodeScalars[..<end]))
        }

        /// The last `count` UTF-16 units of `text`, never half of a character made of two.
        static func lastUnits(_ text: String, _ count: Int) -> String {
            let units = text.utf16
            guard units.count > count else { return text }
            var start = units.index(units.endIndex, offsetBy: -count)
            while start < units.endIndex, start.samePosition(in: text.unicodeScalars) == nil {
                start = units.index(after: start)
            }

            return String(String.UnicodeScalarView(text.unicodeScalars[start...]))
        }
    }

    /// Apps whose web content is described only once an assistive app asks.
    enum WebContent {
        case chromium
        case electron

        var wakeAttribute: String {
            switch self {
            case .chromium: return "AXEnhancedUserInterface"
            case .electron: return "AXManualAccessibility"
            }
        }
    }

    /// One read's calls: after the first that gets no answer, nothing more is asked, since each would wait as long.
    struct Asking {
        private let source: Accessibility
        private(set) var answered = true

        init(_ source: Accessibility) {
            self.source = source
        }

        mutating func ask<T>(_ question: (Accessibility) throws -> T?) -> T? {
            guard answered else { return nil }
            do {
                return try question(source)
            } catch {
                answered = false
                return nil
            }
        }
    }
}
