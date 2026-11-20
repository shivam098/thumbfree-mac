import ThumbFreeCore

/// The language switch (thumbfree-windows `LanguageSwitch`, which Windows' Alt+Shift+H uses): the dictation language
/// lives in settings, and each language keeps its own model. The Mac has no language key yet, so the menu bar sets the
/// language itself, as Windows' tray does.
public enum LanguageSwitch {
    /// English ⇄ Hindi + English. Only the language changes: the tier chosen for each stays as it is.
    public static func toggle(_ settings: SettingsStore) {
        settings.update { $0.language = $0.language == .hinglish ? .english : .hinglish }
    }
}
