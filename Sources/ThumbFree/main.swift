import AppKit
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech

// ThumbFree in the menu bar, for now only so that the app scripts/make-app.sh builds launches: the mark, and a menu
// that says it's in development, with Quit. Dictation (docs/mac.md, phase 3) comes next.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = Pill.Mark.menuBarImage()
    item.button?.toolTip = "ThumbFree \(ThumbFreeCore.version)"

    let menu = NSMenu()
    _ = menu.addItem(withTitle: "ThumbFree for Mac — in development", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    _ = menu.addItem(withTitle: "Quit ThumbFree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu

    withExtendedLifetime(item) {
        app.run()
    }
}
