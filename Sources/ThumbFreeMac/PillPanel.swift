import AppKit
import SwiftUI

extension Pill {
    /// The pill on screen: a borderless, non-activating panel that never takes the focus or a click from the app being
    /// dictated into, on every Space and over full-screen apps. It shows `model.display`, and hides while there's
    /// nothing to show (unless pinned). Main thread only.
    @MainActor
    public final class Panel {
        public private(set) var model: Model

        /// The focused window's frame in Accessibility coordinates (`FocusedField.windowFrame`): the pill goes to the
        /// bottom of that window's screen. Nil: the main screen.
        public var windowFrame: CGRect? {
            didSet { render() }
        }

        private let panel: NSPanel
        private let content: NSHostingController<Content>
        private var fade: Timer?
        private var dots: Timer?

        public init(keyName: String = "Fn") {
            let model = Model(keyName: keyName)
            let content = NSHostingController(rootView: Content(display: model.display))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: true)
            self.model = model
            self.content = content
            self.panel = panel

            content.sizingOptions = []
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.contentView = content.view
            render()
        }

        /// Always on screen, or only while there's something to show (the default).
        public var pinned: Bool {
            get { model.pinned }
            set {
                model.pinned = newValue
                render()
            }
        }

        /// The dictation key, as the texts name it ("Fn", "Right Option"): a setting, so it can change.
        public var keyName: String {
            get { model.keyName }
            set {
                model.keyName = newValue
                render()
            }
        }

        public func showActivity(_ activity: String?) {
            model.showActivity(activity)
            if activity == Pill.transcribing {
                startDots()
            } else {
                dots?.invalidate()
                dots = nil
            }

            render()
        }

        public func showInputLevel(_ level: Float) {
            model.showInputLevel(level)
            render(resize: false)
        }

        public func setPaused(_ paused: Bool) {
            model.setPaused(paused)
            render()
        }

        /// Shows `status` for `Model.messageTime`, counted again from each new one.
        public func showStatus(_ status: Status) {
            model.showStatus(status)
            fade?.invalidate()
            fade = schedule(after: Model.messageTime, repeats: false) { panel in
                panel.fade = nil
                panel.model.fadeStatus()
                panel.render()
            }

            render()
        }

        public func setDictationLanguage(hinglish: Bool, accurate: Bool) {
            model.setDictationLanguage(hinglish: hinglish, accurate: accurate)
            render()
        }

        public func showPreview(_ text: String?) {
            model.showPreview(text)
            render()
        }

        private func startDots() {
            guard dots == nil else { return }
            dots = schedule(after: Model.dotsInterval, repeats: true) { panel in
                panel.model.advanceDots()
                panel.render(resize: false)
            }
        }

        /// A timer on the main run loop that also fires while a menu is open.
        private func schedule(
            after interval: TimeInterval, repeats: Bool, _ action: @escaping @MainActor @Sendable (Panel) -> Void
        ) -> Timer {
            let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }

            RunLoop.main.add(timer, forMode: .common)
            return timer
        }

        /// Draws the display; when the size may have changed, sizes the panel to it and places it.
        private func render(resize: Bool = true) {
            content.rootView = Content(display: model.display)
            guard model.isVisible else {
                if panel.isVisible { panel.orderOut(nil) }
                return
            }

            if resize || !panel.isVisible {
                let size = content.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
                let screens = NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
                let main = NSScreen.main.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
                if let frame = Pill.frame(size: size, window: windowFrame, screens: screens, fallback: main),
                   frame != panel.frame {
                    panel.setFrame(frame, display: true)
                }
            }

            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    /// The pill's look, from the Windows pill (OverlayWindow.xaml): the logo, the dot or the level meter, the activity,
    /// and under it the words heard, the hint, the message and what was heard.
    struct Content: View {
        let display: Display

        var body: some View {
            Limited(width: 560) {
                HStack(spacing: 0) {
                    MarkView(size: 22).padding(.trailing, 8)
                    indicator.padding(.trailing, 10)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text(display.mode)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(pill: .white))
                            if let dots = display.dots {
                                Text(dots)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(pill: .white))
                                    .frame(width: 14, alignment: .leading)
                            }

                            if let badge = display.badge {
                                Text(badge)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(pill: .badgeText))
                                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 1, trailing: 6))
                                    .background { RoundedRectangle(cornerRadius: 6).fill(Color(pill: .badge)) }
                                    .padding(.leading, 8)
                            }
                        }

                        if let preview = display.preview {
                            Limited(width: 440) {
                                Text(preview).font(.system(size: 13)).foregroundStyle(Color(pill: .text)).lineLimit(3)
                            }
                            .opacity(display.previewOpacity)
                            .padding(.top, 3)
                        }

                        if let hint = display.hint {
                            Text(hint).font(.system(size: 11)).foregroundStyle(Color(pill: .muted)).padding(.top, 2)
                        }

                        if let message = display.message {
                            Limited(width: 500) {
                                Text(message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(pill: display.messageColour))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        if let heard = display.heard {
                            Limited(width: 500) {
                                Text(heard)
                                    .font(.system(size: 11))
                                    .italic()
                                    .foregroundStyle(Color(pill: .muted))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(pill: .background)) }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(pill: .border), lineWidth: 1)
                }
            }
            .fixedSize()
        }

        /// The level meter while listening, else the dot (fading in and out while transcribing).
        @ViewBuilder private var indicator: some View {
            if let bars = display.bars {
                HStack(spacing: 2) {
                    ForEach(bars.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(pill: .recording))
                            .frame(width: 3, height: bars[index])
                    }
                }
                .frame(height: 18)
            } else if let dot = display.dot, display.dotPulses {
                PulsingDot(colour: dot)
            } else if let dot = display.dot {
                Circle().fill(Color(pill: dot)).frame(width: 10, height: 10)
            }
        }
    }

    /// The dot while transcribing: fades to 30% and back, `Model.pulseTime` each way, from when it appears.
    struct PulsingDot: View {
        let colour: Colour
        @State private var faded = false

        var body: some View {
            Circle()
                .fill(Color(pill: colour))
                .frame(width: 10, height: 10)
                .opacity(faded ? 0.3 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: Model.pulseTime).repeatForever(autoreverses: true)) {
                        faded = true
                    }
                }
        }
    }

    /// Lays its view out at its own width up to `width`, wrapping or truncating text beyond it, as a TextBlock with a
    /// MaxWidth does on Windows. (A frame's maxWidth gives text nothing to wrap at when the pill sizes itself.)
    struct Limited: Layout {
        var width: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let view = subviews.first else { return .zero }
            let limit = min(width, proposal.width ?? width)
            let natural = view.sizeThatFits(.unspecified)
            return natural.width <= limit ? natural : view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    /// The logo: the white microphone on its tile.
    struct MarkView: View {
        let size: CGFloat

        var body: some View {
            let tile = size - 2 * Mark.inset(size)
            ZStack {
                RoundedRectangle(cornerRadius: tile * 0.22).fill(Color(pill: .tile)).frame(width: tile, height: tile)
                MicrophoneShape().fill(Color(pill: .white))
            }
            .frame(width: size, height: size)
        }
    }

    struct MicrophoneShape: Shape {
        nonisolated func path(in rect: CGRect) -> Path {
            let size = min(rect.width, rect.height)
            let unit = (size - 2 * Mark.inset(size)) / Mark.visibleUnits
            let offset = CGPoint(x: rect.midX - unit * Mark.centreOffset, y: rect.midY - unit * Mark.centreOffset)
            return Path(Mark.microphone(scale: unit * Mark.groupScale, offset: offset))
        }
    }

    /// ThumbFree's mark, the same on every platform (thumbfree-windows assets/make-logo.ps1): the Android launcher
    /// icon's Material microphone, white on a rounded tile.
    public enum Mark {
        /// The launcher icon is 108 units, of which the middle 72 show; the 24-unit microphone in it is scaled 1.9 and
        /// moved 31.2 units, so its centre is 22.8 scaled units before the icon's.
        static let visibleUnits: CGFloat = 72
        static let groupScale: CGFloat = 1.9
        static let centreOffset: CGFloat = 54 - 31.2

        /// The space around the tile: 6 of every 256 points.
        static func inset(_ size: CGFloat) -> CGFloat { size * 6 / 256 }

        /// The microphone alone, as a template image for the menu bar: the Material icon's 24 units in 18 points.
        public static func menuBarImage() -> NSImage {
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.addPath(Mark.microphone(scale: 0.75, offset: .zero))
                context.fillPath()
                return true
            }

            image.isTemplate = true
            image.accessibilityDescription = "ThumbFree"
            return image
        }

        /// The Material "mic" path (ic_launcher_foreground.xml), y down, `scale` points per unit from `offset`.
        static func microphone(scale: CGFloat, offset: CGPoint) -> CGPath {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
            }

            let path = CGMutablePath()
            // The capsule.
            path.move(to: point(12, 14))
            path.addCurve(to: point(14.99, 11), control1: point(13.66, 14), control2: point(14.99, 12.66))
            path.addLine(to: point(15, 5))
            path.addCurve(to: point(12, 2), control1: point(15, 3.34), control2: point(13.66, 2))
            path.addCurve(to: point(9, 5), control1: point(10.34, 2), control2: point(9, 3.34))
            path.addLine(to: point(9, 11))
            path.addCurve(to: point(12, 14), control1: point(9, 12.66), control2: point(10.34, 14))
            path.closeSubpath()
            // The stand.
            path.move(to: point(17.3, 11))
            path.addCurve(to: point(12, 16.1), control1: point(17.3, 14), control2: point(14.76, 16.1))
            path.addCurve(to: point(6.7, 11), control1: point(9.24, 16.1), control2: point(6.7, 14))
            path.addLine(to: point(5, 11))
            path.addCurve(to: point(11, 17.72), control1: point(5, 14.41), control2: point(7.72, 17.23))
            path.addLine(to: point(11, 21))
            path.addLine(to: point(13, 21))
            path.addLine(to: point(13, 17.72))
            path.addCurve(to: point(19, 11), control1: point(16.28, 17.24), control2: point(19, 14.42))
            path.closeSubpath()
            return path
        }
    }
}

private extension Color {
    init(pill colour: Pill.Colour) {
        self.init(
            .sRGB,
            red: Double((colour.rgb >> 16) & 0xFF) / 255,
            green: Double((colour.rgb >> 8) & 0xFF) / 255,
            blue: Double(colour.rgb & 0xFF) / 255,
            opacity: colour.alpha)
    }
}
