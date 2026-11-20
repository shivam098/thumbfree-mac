import ThumbFreeCore

/// The Mac side of dictation (docs/mac.md): the Fn hotkey, the microphone, the text box, typing, the pill and the
/// permissions land here.
public enum ThumbFreeMac {
    public static let coreVersion = ThumbFreeCore.version

    /// ThumbFree for Mac's bundle identifier (Android's is "app.thumbfree.android").
    public static let thumbFreeBundleIdentifier = "app.thumbfree.mac"

    /// Jarvis for Mac's (mac-voice-assistant). It uses Fn too, so each app warns while the other runs (OtherApp).
    public static let jarvisBundleIdentifier = "io.github.shivam098.voiceassistant"
}
