import CoreGraphics
import Foundation

/// The status pill at the bottom of the screen (docs/mac.md, "Shape"), as thumbfree-windows `OverlayWindow`: the voice
/// level while you speak, the words not typed yet, "Transcribing…", and messages. `Model` decides what it shows, with
/// the same states, texts, colours and timings as Windows; `Panel` puts that on screen.
public enum Pill {
    /// Recording: the level meter, the words heard so far and how to finish.
    public static let listening = "Listening…"

    /// Recording has stopped and the speech is being turned into text.
    public static let transcribing = "Transcribing…"

    /// A colour, as the Windows pill writes it (#RRGGBB and an opacity).
    public struct Colour: Equatable, Sendable {
        public let rgb: UInt32
        public let alpha: Double

        public init(_ rgb: UInt32, alpha: Double = 1) {
            self.rgb = rgb
            self.alpha = alpha
        }

        public static let white = Colour(0xFFFFFF)
        public static let text = Colour(0xE8EAED)
        public static let muted = Colour(0x9AA0A6)
        public static let ready = Colour(0x81C995)
        public static let recording = Colour(0xEA4335)
        public static let busy = Colour(0xFBBC04)
        public static let warning = Colour(0xFDD663)
        public static let error = Colour(0xF28B82)
        public static let background = Colour(0x202124, alpha: Double(0xE6) / 255)
        public static let border = Colour(0xFFFFFF, alpha: Double(0x33) / 255)
        public static let badge = Colour(0x4C8DF6, alpha: Double(0x33) / 255)
        public static let badgeText = Colour(0xC6DAFC)
        /// The logo's tile (the Android launcher colour).
        public static let tile = Colour(0x5B4BDB)
    }

    /// A message from dictation, as Windows' StatusUpdate.
    public struct Status: Equatable, Sendable {
        public enum Kind: Sendable {
            case info
            case success
            case warning
            case error
        }

        public var kind: Kind
        public var message: String
        /// What was heard, shown under a problem.
        public var heard: String?

        public init(_ kind: Kind, _ message: String, heard: String? = nil) {
            self.kind = kind
            self.message = message
            self.heard = heard
        }
    }

    /// What the pill draws now. Nil parts aren't shown.
    public struct Display: Equatable {
        /// "Ready · tap Fn to dictate", "Listening…", "Transcribing" (its dots follow), or another activity.
        public let mode: String
        /// After "Transcribing": "", ".", ".." or "...", in a slot of their own so the text doesn't move.
        public let dots: String?
        /// The dot before the text (not while listening, when the level meter takes its place).
        public let dot: Colour?
        /// The dot fades in and out (`Model.pulseTime` each way) while transcribing.
        public let dotPulses: Bool
        /// The level meter's five bars, in points (4 to 18), while listening.
        public let bars: [Double]?
        /// "HI + EN" while dictation is in Hindi + English.
        public let badge: String?
        /// The words heard so far.
        public let preview: String?
        /// Dimmed while transcribing.
        public let previewOpacity: Double
        /// How to finish, while listening.
        public let hint: String?
        public let message: String?
        public let messageColour: Colour
        /// "Heard: “…”" under a problem.
        public let heard: String?
    }

    /// What the pill shows: Windows' OverlayWindow without the window, so it can be tested. The panel calls
    /// `fadeStatus` `messageTime` after the latest `showStatus`, and `advanceDots` every `dotsInterval` while
    /// transcribing.
    public struct Model: Equatable {
        /// How long a message stays.
        public static let messageTime: TimeInterval = 5
        /// How often the dots after "Transcribing" move.
        public static let dotsInterval: TimeInterval = 0.35
        /// How long the dot takes to fade out, or back in, while transcribing.
        public static let pulseTime: TimeInterval = 0.5
        /// The most of the words heard that's shown (the latest), in UTF-16 units as on Windows.
        public static let previewLimit = 150

        /// The level meter's bars, middle tallest.
        static let barWeights: [Double] = [0.55, 0.8, 1.0, 0.8, 0.55]

        /// The dictation key, as the texts name it.
        public var keyName: String
        /// Shown all the time; otherwise only while there's something to show.
        public var pinned = false
        /// `Pill.listening`, `Pill.transcribing`, or another short label such as "Loading speech model…"; nil while
        /// idle.
        public private(set) var activity: String?
        /// The dictation key is paused.
        public private(set) var paused = false
        /// The voice level, 0 to 1: up at once, down gently.
        public private(set) var level: Double = 0
        public private(set) var bars = Model.heights(0) { 1 }
        public private(set) var preview: String?
        public private(set) var message: String?
        public private(set) var messageKind = Status.Kind.info
        public private(set) var heard: String?
        public private(set) var dotCount = 0
        public private(set) var hinglish = false
        public private(set) var accurate = false

        public init(keyName: String = "Fn") {
            self.keyName = keyName
        }

        /// Anything to show: the panel is on screen only then (or when pinned).
        public var isVisible: Bool {
            pinned || activity != nil || preview != nil || message != nil || heard != nil
        }

        /// Shows what's happening; nil goes back to the resting label. Listening shows the level meter and how to
        /// finish; transcribing animates until the text is typed, keeping the words heard on screen, dimmed.
        public mutating func showActivity(_ activity: String?) {
            let wasTranscribing = self.activity == Pill.transcribing
            self.activity = activity
            if activity == Pill.listening {
                level = 0
                bars = Self.heights(0) { 1 }
            }

            let transcribing = activity == Pill.transcribing
            if transcribing, !wasTranscribing {
                dotCount = 0
            }

            if wasTranscribing, !transcribing {
                // The words heard stayed on screen while transcribing; the typed text replaces them.
                preview = nil
            }
        }

        /// Moves the level meter while listening (`level` from 0 to 1). `jitter` (0 to 1) wobbles the bars a little.
        public mutating func showInputLevel(_ level: Float, jitter: () -> Double = { Double.random(in: 0..<1) }) {
            guard activity == Pill.listening else { return }

            // Up at once, down gently, like a VU meter.
            let now = Double(level)
            self.level = now > self.level ? now : self.level * 0.6 + now * 0.4
            bars = Self.heights(self.level, jitter: jitter)
        }

        public mutating func setPaused(_ paused: Bool) {
            self.paused = paused
        }

        /// A message, until `fadeStatus`. "Typed." stays quiet: the text is on screen where the cursor is. What was
        /// heard shows under anything but a success.
        public mutating func showStatus(_ status: Status) {
            let typed = status.kind == .success && status.message == "Typed."
            message = status.message.isEmpty || typed ? nil : status.message
            messageKind = status.kind
            let heardText = status.heard ?? ""
            heard = heardText.isEmpty || status.kind == .success ? nil : "Heard: “\(heardText)”"
        }

        /// The message and what was heard go, `messageTime` after the latest one came.
        public mutating func fadeStatus() {
            message = nil
            heard = nil
        }

        /// The "HI + EN" badge while dictation is in Hindi + English ("HI + EN · accurate" with the larger model).
        public mutating func setDictationLanguage(hinglish: Bool, accurate: Bool) {
            self.hinglish = hinglish
            self.accurate = accurate
        }

        /// The words heard so far, with line breaks as " ↵ "; nil or empty hides them, except while transcribing, when
        /// the last words stay until the text is typed. Long text keeps its latest words. Hides the message.
        public mutating func showPreview(_ text: String?) {
            let shown = text?.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ↵ ") ?? ""
            guard !shown.isEmpty else {
                if activity != Pill.transcribing {
                    preview = nil
                }

                return
            }

            preview = Self.latestWords(shown)
            message = nil
            heard = nil
        }

        /// The dots after "Transcribing" move on: "", ".", "..", "...", then "" again.
        public mutating func advanceDots() {
            dotCount = (dotCount + 1) % 4
        }

        public var display: Display {
            let listening = activity == Pill.listening
            let transcribing = activity == Pill.transcribing
            let mode: String
            let dot: Colour?
            if let activity {
                mode = transcribing ? "Transcribing" : activity
                dot = listening ? nil : .busy
            } else {
                mode = paused ? "Paused · dictation keys are off" : "Ready · tap \(keyName) to dictate"
                dot = paused ? .muted : .ready
            }

            let colour: Colour
            switch messageKind {
            case .info: colour = .text
            case .success: colour = .ready
            case .warning: colour = .warning
            case .error: colour = .error
            }

            return Display(
                mode: mode,
                dots: transcribing ? String(repeating: ".", count: dotCount) : nil,
                dot: dot,
                dotPulses: transcribing,
                bars: listening ? bars : nil,
                badge: hinglish ? (accurate ? "HI + EN · accurate" : "HI + EN") : nil,
                preview: preview,
                previewOpacity: transcribing ? 0.6 : 1,
                hint: listening ? "\(keyName) to finish · Esc to cancel" : nil,
                message: message,
                messageColour: colour,
                heard: heard)
        }

        /// The bars' heights for `level`: 4 points, up to 18 for the middle one at full level, each wobbling by up to
        /// 20% once there's sound.
        static func heights(_ level: Double, jitter: () -> Double) -> [Double] {
            barWeights.map { weight in
                let wobble = level > 0.05 ? 0.8 + jitter() * 0.4 : 1
                return 4 + 14 * min(max(level * weight * wobble, 0), 1)
            }
        }

        /// The last `previewLimit` UTF-16 units after "…", from the first word that starts in them.
        static func latestWords(_ text: String) -> String {
            let units = Array(text.utf16)
            guard units.count > previewLimit else { return text }
            let start = units.count - previewLimit
            var from = start
            if let space = units[start...].firstIndex(of: 0x20), space > 0, space < units.count - 1 {
                from = space + 1
            }

            while from < units.count, UTF16.isTrailSurrogate(units[from]) {
                from += 1
            }

            return "…" + String(decoding: units[from...], as: UTF16.self)
        }
    }

    /// A display, in AppKit coordinates (from the bottom left of the main display, y up).
    public struct Screen: Equatable, Sendable {
        public var frame: CGRect
        /// Without the menu bar and the Dock.
        public var visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// How far above the bottom of the screen's visible area (the Dock's top) the pill sits.
    public static let bottomMargin: CGFloat = 16

    /// The pill's frame: centred at the bottom of the screen that has most of `window`, the focused window's frame in
    /// Accessibility coordinates (from the top left of the main display, y down: `FocusedField.windowFrame`), else of
    /// `screens[fallback]`. `screens` start with the main display, as NSScreen.screens does; nil when there are none.
    public static func frame(size: CGSize, window: CGRect?, screens: [Screen], fallback: Int = 0) -> CGRect? {
        guard let main = screens.first else { return nil }
        var chosen = screens.indices.contains(fallback) ? screens[fallback] : main
        if let window {
            let flipped = CGRect(
                x: window.minX, y: main.frame.maxY - window.maxY, width: window.width, height: window.height)
            var most: CGFloat = 0
            for screen in screens {
                let overlap = screen.frame.intersection(flipped)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > most {
                    most = area
                    chosen = screen
                }
            }
        }

        let area = chosen.visibleFrame
        let x = (area.midX - size.width / 2).rounded()
        return CGRect(x: x, y: area.minY + bottomMargin, width: size.width, height: size.height)
    }
}
