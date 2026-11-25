import Foundation
import ThumbFreeCore

/// The Mac side of dictation (docs/mac.md): the Fn hotkey, the microphone, the text box, typing, the pill and the
/// permissions land here.
public enum ThumbFreeMac {
    public static let coreVersion = ThumbFreeCore.version

    /// ThumbFree for Mac's bundle identifier (Android's is "app.thumbfree.android").
    public static let thumbFreeBundleIdentifier = "app.thumbfree.mac"

    /// Jarvis for Mac's (mac-voice-assistant). It uses Fn too, so each app warns while the other runs (OtherApp).
    public static let jarvisBundleIdentifier = "io.github.shivam098.voiceassistant"

    /// The name of the app these libraries run in, for the texts that name it: ThumbFree in ThumbFree, Jarvis in
    /// Jarvis. Its bundle's CFBundleDisplayName, else its CFBundleName, else the process's name.
    static var appName: String {
        nameOfApp(
            info: { Bundle.main.object(forInfoDictionaryKey: $0) }, processName: ProcessInfo.processInfo.processName)
    }

    /// `appName` from the bundle's Info.plist values (`info`, by key) and the process's name; "This app" when all
    /// are empty.
    static func nameOfApp(info: (String) -> Any?, processName: String) -> String {
        let names = [info("CFBundleDisplayName"), info("CFBundleName")].compactMap { $0 as? String } + [processName]
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed.first { !$0.isEmpty } ?? "This app"
    }
}
