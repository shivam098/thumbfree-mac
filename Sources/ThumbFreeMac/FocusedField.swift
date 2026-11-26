import ApplicationServices
import Foundation

/// The text box a dictation is for, read with the Accessibility API once when it starts (docs/mac.md, "Typing into
/// other apps"): what kind of box it is, the text before the cursor, the app and window it's in, and how to recognise
/// it again, so text only ever goes into that same box. The Mac side of thumbfree-windows `FocusedField` and
/// `FocusInspector`. These are the facts only: the rules that use them (which apps and pages get email layout,
/// private windows, what History keeps) are the core's. Nothing read here is logged or kept.
public struct FocusedField: Sendable {
    /// The app the box is in, as you see it: the app taking the keys. That's Safari even where WebKit's helper process
    /// describes the page, and Spotlight while the app before it stays in front.
    public struct App: Equatable, Sendable {
        public var processIdentifier: pid_t
        public var bundleIdentifier: String?
        public var name: String?
        /// Built with Electron (Slack, VS Code, Discord…), whose pages are described only once asked: see
        /// `Reader.startWaking`.
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

    /// How `Reader.isSameField` recognises the box again: the element itself, or, while a web app hasn't described its
    /// page yet (its focus is on the page or the window), the page or window it's in, as Windows compares the window.
    enum Identity {
        case box(Element)
        case page(Element)
        case window(Element)
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
    /// False while a Chromium or Electron app hasn't described its page yet (it does 2 s after it's woken): the focus
    /// is on the page or the window, so what kind of box it is and its text aren't known. `Reader.resolved` reads it
    /// again, before the first piece is typed.
    public let isResolved: Bool
    /// True or false when the box says so (AXTextArea takes line breaks; text fields, combo boxes, search and password
    /// boxes don't); nil when it doesn't, as on Windows, where such boxes are treated as taking them.
    public let takesLineBreaks: Bool?
    /// The text before the cursor, at most the last `Reader.maxTextBefore` UTF-16 units; nil when the box doesn't say.
    public let textBefore: String?
    /// False when the box gave no cursor: the text before it is then the end of its text.
    public let caretKnown: Bool
    /// IsSecureEventInputEnabled(): whether a password is being typed somewhere, when nothing may be typed.
    public let secureInput: SecureInput
    let identity: Identity
    /// The web page and the window the box is in, to match it with the box once its page has described itself.
    let page: Element?
    let window: Element?

    /// For logs: the kind of box, never its text or title ("AXTextArea multi-line web").
    public var kind: String {
        var kind = role ?? "no role"
        if let subrole { kind += "/" + subrole }
        if let takesLineBreaks { kind += takesLineBreaks ? " multi-line" : " single-line" }
        if isSearch { kind += " search" }
        if isSecure { kind += " secure" }
        if isInWebPage { kind += " web" }
        if !isResolved { kind += " unresolved" }
        switch secureInput {
        case .off: break
        case .on: kind += " secure-input"
        case .unknown: kind += " secure-input-unknown"
        }

        return kind
    }
}

extension FocusedField {
    /// What the reader asks the system, behind a protocol so the reading can be tested without other apps
    /// (FakeAXSystem in the tests): the Accessibility API, with AXUIElements as elements, and which app is in front
    /// (NSWorkspace). A missing attribute is nil; a call that gets no answer throws `NoAnswer`.
    public protocol Accessibility: AnyObject {
        /// The app accepting keyboard input (kAXFocusedApplicationAttribute, system-wide): Safari, not the WebKit
        /// process that describes its pages; Spotlight, not the app left in front.
        func focusedApplication() throws -> AnyObject?
        /// The element with the keyboard focus, in whichever app has it (kAXFocusedUIElementAttribute, system-wide).
        func focusedElement() throws -> AnyObject?
        func string(_ attribute: String, of element: AnyObject) throws -> String?
        /// A number attribute, such as kAXNumberOfCharactersAttribute.
        func integer(_ attribute: String, of element: AnyObject) throws -> Int?
        /// A range attribute, such as kAXSelectedTextRangeAttribute: in UTF-16 units, as NSString counts.
        func range(_ attribute: String, of element: AnyObject) throws -> CFRange?
        /// A text attribute for `range`, such as kAXStringForRangeParameterizedAttribute, as UTF-16 units: a range
        /// can cut an emoji in two, and a Swift string can't hold its halves.
        func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]?
        func element(_ attribute: String, of element: AnyObject) throws -> AnyObject?
        /// kAXPositionAttribute and kAXSizeAttribute together.
        func frame(of element: AnyObject) throws -> CGRect?
        func processIdentifier(of element: AnyObject) throws -> pid_t
        /// The app's own element (AXUIElementCreateApplication).
        func application(_ processIdentifier: pid_t) -> AnyObject
        /// Sets a true/false attribute, and says how the app answered.
        func setFlag(_ attribute: String, _ value: Bool, of element: AnyObject) -> FlagAnswer
        /// The same element (CFEqual).
        func isSame(_ element: AnyObject, as other: AnyObject) -> Bool
        func app(_ processIdentifier: pid_t) -> App
        /// The app in front (NSWorkspace), known without asking the app anything: for when Accessibility can't answer.
        var frontmostProcess: pid_t? { get }
        /// Calls `handler`, off the main thread, with each app that comes to the front (NSWorkspace's
        /// didActivateApplicationNotification), for as long as the returned object is kept. The main thread posts
        /// the notification and waits for its observers, so it mustn't wait for `handler` too.
        func observeActivations(_ handler: @escaping @Sendable (pid_t) -> Void) -> AnyObject
        /// IsSecureEventInputEnabled(), asked on the main thread (`SecureInput.current`).
        var secureInput: SecureInput { get }
    }

    /// How an app answered a flag set on it (`Accessibility.setFlag`).
    public enum FlagAnswer: Equatable, Sendable {
        /// It took the flag.
        case taken
        /// It answered that it has no such attribute, which doesn't mean it ignored it: Chromium acts on
        /// AXEnhancedUserInterface, then hands it on to AppKit, whose answer that is.
        case unsupported
        /// No answer: Accessibility is off for ThumbFree, the app didn't answer in time (one still starting, say), or
        /// it has gone.
        case noAnswer
    }

    /// Reads the focused box when a dictation starts (`read`), again once a web page has described it (`resolved`),
    /// and checks it before each piece is typed (`isSameField`). Safe to use from any thread; its calls wait while the
    /// app answers (a second at most each), so keep them off the main thread.
    public final class Reader: @unchecked Sendable {
        /// The most text before the cursor that's kept, in UTF-16 units (C# chars on Windows).
        public static let maxTextBefore = 2000

        /// The most parents looked at for the page and the window around the box.
        static let maxDepth = 60

        /// Chromium browsers, by bundle identifier (betas and other channels add to it after a dot).
        static let chromiumBrowsers = [
            "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium",
            "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser",
        ]

        private let source: Accessibility
        private let ownProcess = ProcessInfo.processInfo.processIdentifier
        private let lock = NSLock()
        private var wakes = true
        private var woken: Set<String> = []
        private var activations: AnyObject?

        /// Reads with the Accessibility API itself.
        public convenience init() {
            self.init(source: SystemAccessibility())
        }

        public init(source: Accessibility) {
            self.source = source
        }

        /// Chrome, Edge, Brave and the other Chromium browsers, and Electron apps, describe their pages only once an
        /// assistive app asks, the way VoiceOver does: such an app gets AXEnhancedUserInterface (Chromium) or
        /// AXManualAccessibility (Electron) once while it runs (`startWaking`). True by default; to be measured on a
        /// real Mac (docs/mac.md).
        public var wakesWebContent: Bool {
            get { lock.withLock { wakes } }
            set { lock.withLock { wakes = newValue } }
        }

        /// Wakes Chromium and Electron apps before any dictation: the app in front now, then each one as it comes to
        /// the front. Chromium (and Electron since 38) turns its page descriptions on 2 s after the last time it's
        /// asked, too late for a dictation starting then. Call it once, when ThumbFree starts; the wakes happen off the
        /// main thread, which never waits for them (an app still launching can take a second to answer).
        public func startWaking() {
            let started: Bool = lock.withLock {
                guard activations == nil else { return false }
                activations = source.observeActivations { [weak self] pid in _ = self?.wake(pid) }
                return true
            }

            guard started, let front = source.frontmostProcess else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in _ = self?.wake(front) }
        }

        /// Wakes the app `pid` if it's a Chromium or Electron app that hasn't been asked yet: each app is asked once
        /// while it runs. An app that answered counts as asked even when it said it has no such attribute: Chromium
        /// answers that while acting on the flag, and turns its page descriptions on 2 s after the last time it's
        /// asked, so asking it again at each activation or dictation would only put them off. An app that didn't
        /// answer (still starting, say) is asked again next time. True when this asked it.
        @discardableResult
        func wake(_ pid: pid_t) -> Bool {
            guard wakesWebContent, pid != ownProcess else { return false }
            let app = source.app(pid)
            guard let web = Self.webContent(of: app) else { return false }
            let key = "\(app.processIdentifier) \(app.bundleIdentifier ?? "")"
            // Taken before asking, so an activation and a dictation starting at the same moment ask once.
            guard lock.withLock({ woken.insert(key).inserted }) else { return false }
            guard source.setFlag(web.wakeAttribute, true, of: source.application(pid)) != .noAnswer else {
                lock.withLock { _ = woken.remove(key) }
                return false
            }

            return true
        }

        /// The box with the keyboard focus now, or nil when Accessibility can't tell (it's off for ThumbFree, or the
        /// app didn't answer in time), nothing has the focus, or the focus is in ThumbFree itself. Never waits: in a
        /// Chromium or Electron app that hasn't described its page yet, the box comes back unresolved (`isResolved`
        /// false; the app is woken if it wasn't), for `resolved` to read again.
        public func read() -> FocusedField? {
            snapshot(waking: true)
        }

        /// `start` once its page has described it: when `start` isn't resolved, the box with the focus now if it's a
        /// text box in the same app and page (or, without a page, the same window); nil while there's none. Call it
        /// just before the first piece is typed. A resolved `start` comes back as it is.
        public func resolved(_ start: FocusedField) -> FocusedField? {
            if start.isResolved {
                return start
            }

            guard let now = snapshot(waking: false), now.isResolved,
                  now.app.processIdentifier == start.app.processIdentifier else { return nil }
            switch start.identity {
            case .box:
                return nil
            case .page(let page):
                return now.page.map { source.isSame($0.object, as: page.object) } == true ? now : nil
            case .window(let window):
                return now.window.map { source.isSame($0.object, as: window.object) } == true ? now : nil
            }
        }

        /// True when the focus is still in `start`'s box (the same AXUIElement, CFEqual; while its page hasn't
        /// described it, the same page or window), false when Accessibility says it's somewhere else. The app in front
        /// matters only when Accessibility can't tell (an app that doesn't answer): nil while `start`'s app is still in
        /// front, as Windows answers null only in the same window, else false. A box in a panel that takes the keys
        /// while another app stays in front (Spotlight, a notification's reply) is still the same box. Never wakes
        /// anything.
        public func isSameField(_ start: FocusedField) -> Bool? {
            var asking = Asking(source)
            guard let found = focus(&asking) else {
                if asking.answered {
                    return false
                }

                return source.frontmostProcess == start.app.processIdentifier ? nil : false
            }

            guard found.pid == start.app.processIdentifier else { return false }
            let focused = found.element
            switch start.identity {
            case .box(let box):
                return source.isSame(focused, as: box.object)
            case .page(let page):
                let role = asking.ask { try $0.string(kAXRoleAttribute, of: focused) }
                let around = containers(of: focused, role: role, pid: found.pid, &asking)
                if let pageNow = around.page {
                    return source.isSame(pageNow, as: page.object)
                }

                return asking.answered ? false : nil
            case .window(let window):
                let role = asking.ask { try $0.string(kAXRoleAttribute, of: focused) }
                let around = containers(of: focused, role: role, pid: found.pid, &asking)
                if let windowNow = around.window {
                    return source.isSame(windowNow, as: window.object)
                }

                return asking.answered ? false : nil
            }
        }

        private func snapshot(waking: Bool) -> FocusedField? {
            var asking = Asking(source)
            guard let found = focus(&asking), found.pid != ownProcess else { return nil }
            let element = found.element
            let pid = found.pid

            let app = source.app(pid)
            let web = Self.webContent(of: app)
            if waking, web != nil {
                wake(pid)
            }

            let role = asking.ask { try $0.string(kAXRoleAttribute, of: element) }
            let subrole = asking.ask { try $0.string(kAXSubroleAttribute, of: element) }
            guard asking.answered else { return nil }

            let resolved = web == nil || Self.isBox(role: role, subrole: subrole)
            let (page, window) = containers(of: element, role: role, pid: pid, &asking)
            let identity: Identity
            if resolved {
                identity = .box(Element(element))
            } else if let page {
                identity = .page(Element(page))
            } else if let window {
                identity = .window(Element(window))
            } else if asking.answered {
                // No page or window to recognise it by: only this element counts.
                identity = .box(Element(element))
            } else {
                // Where the box is couldn't be told, so neither could whether the focus left it.
                return nil
            }

            let secure = role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
            let title = window.flatMap { window in asking.ask { try $0.string(kAXTitleAttribute, of: window) } }
            let frame = window.flatMap { window in asking.ask { try $0.frame(of: window) } }
            let search = role == kAXSearchFieldSubrole || subrole == kAXSearchFieldSubrole
                || (!secure && saysSearch(element, &asking))
            let lines: Bool? = secure || search ? false : Self.takesLineBreaks(role: role)
            let (before, caretKnown) = secure ? (nil, false) : textBefore(element, &asking)
            return FocusedField(
                app: app, windowTitle: title, windowFrame: frame, role: role, subrole: subrole, isSecure: secure,
                isSearch: search, isInWebPage: page != nil, isResolved: resolved, takesLineBreaks: lines,
                textBefore: before, caretKnown: caretKnown, secureInput: source.secureInput,
                identity: identity, page: page.map(Element.init), window: window.map(Element.init))
        }

        /// The element with the keyboard focus, and the app it's in as you see it: the app taking the keys (the
        /// system-wide kAXFocusedApplicationAttribute), else the element's own process. Safari takes the keys while
        /// WebKit's helper process describes its pages, and Spotlight's box or a notification's reply takes them while
        /// another app stays in front. Nil when nothing has the focus or Accessibility can't tell (`asking.answered`
        /// says which).
        private func focus(_ asking: inout Asking) -> (element: AnyObject, pid: pid_t)? {
            let app = asking.ask { try $0.focusedApplication() }
            let appProcess = app.flatMap { app in asking.ask { try $0.processIdentifier(of: app) } }
            guard let element = focusedElement(in: appProcess, &asking),
                  let pid = appProcess ?? asking.ask({ try $0.processIdentifier(of: element) }) else { return nil }
            return (element, pid)
        }

        /// The element with the keyboard focus: from the system-wide element, else from the app taking the keys (or,
        /// when that isn't known either, the app in front), which some apps answer when the system-wide element
        /// doesn't.
        private func focusedElement(in appProcess: pid_t?, _ asking: inout Asking) -> AnyObject? {
            if let focused = asking.ask({ try $0.focusedElement() }) {
                return focused
            }

            guard asking.answered, let owner = appProcess ?? source.frontmostProcess, owner != ownProcess else {
                return nil
            }

            return asking.ask { try $0.element(kAXFocusedUIElementAttribute, of: $0.application(owner)) }
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

        /// The last `maxTextBefore` UTF-16 units before the cursor (kAXSelectedTextRangeAttribute's start), fetched on
        /// their own (kAXStringForRangeParameterizedAttribute), one unit more so an emoji cut at the start can go;
        /// without a cursor, the end of the text (kAXNumberOfCharactersAttribute). Only a box that can't give a range
        /// is read whole (kAXValueAttribute), as Terminal's scrollback or a long document would be big.
        private func textBefore(_ element: AnyObject, _ asking: inout Asking) -> (String?, Bool) {
            let fetched = Self.maxTextBefore + 1
            let cursor = asking.ask { try $0.range(kAXSelectedTextRangeAttribute, of: element) }
            if let cursor, cursor.location >= 0 {
                if cursor.location == 0 {
                    return ("", true)
                }

                let start = max(0, cursor.location - fetched)
                if let units = textUnits(of: element, from: start, to: cursor.location, &asking) {
                    return (Self.lastUnits(Self.text(units), Self.maxTextBefore), true)
                }

                let value = asking.ask { try $0.string(kAXValueAttribute, of: element) }
                let before = value.map { Self.lastUnits(Self.firstUnits($0, cursor.location), Self.maxTextBefore) }
                return (before, before != nil)
            }

            if let count = asking.ask({ try $0.integer(kAXNumberOfCharactersAttribute, of: element) }), count >= 0,
               let units = textUnits(of: element, from: max(0, count - fetched), to: count, &asking) {
                return (Self.lastUnits(Self.text(units), Self.maxTextBefore), false)
            }

            let value = asking.ask { try $0.string(kAXValueAttribute, of: element) }
            return (value.map { Self.lastUnits($0, Self.maxTextBefore) }, false)
        }

        /// The box's text from `start` to `end`, in UTF-16 units (kAXStringForRangeParameterizedAttribute); nil when
        /// it can't give a range.
        private func textUnits(of element: AnyObject, from start: Int, to end: Int, _ asking: inout Asking)
            -> [UInt16]?
        {
            let range = CFRange(location: start, length: end - start)
            return asking.ask { try $0.utf16(kAXStringForRangeParameterizedAttribute, for: range, of: element) }
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

        /// Text from UTF-16 units that a range may have cut: half an emoji at either end goes.
        static func text(_ units: [UInt16]) -> String {
            var whole = units[...]
            if let first = whole.first, UTF16.isTrailSurrogate(first) {
                whole = whole.dropFirst()
            }

            if let last = whole.last, UTF16.isLeadSurrogate(last) {
                whole = whole.dropLast()
            }

            return String(decoding: whole, as: UTF16.self)
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
