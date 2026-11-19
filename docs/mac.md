# ThumbFree for Mac: design and plan

The feature reference every ThumbFree app follows is
[PLAN.md, section 3](https://github.com/shivam098/thumbfree-android/blob/main/docs/PLAN.md#3-feature-reference-built-on-android-copy-to-every-platform).
This page is the Mac side: how each feature is built here, and in what order.

## Decisions (November 2026)

- **One repo per platform:** thumbfree-android, thumbfree-windows, thumbfree-mac and thumbfree-ios. Each has its own
  copy of the shared test data (`tests/vectors`, `tests/audio`), and a CI check fails while the copies differ.
- **Two Mac apps, one Mac engine.** ThumbFree (private dictation, no wake word) is built here first. Jarvis (dictation
  plus "Hey Jarvis" commands and the AI brain) follows in its own repo, mac-voice-assistant, reusing this repo's Swift
  packages for audio, speech, the hotkey, the pill and typing.
- **Same hotkey for both: Fn (🌐).** Run one app at a time; each one warns you when the other is running, as on Windows.
- **The core is Swift.** The shared logic (formatting, emails, lists and corrections, live typing, field rules, the word
  list) is a Swift version of the Windows C# core, held to the same test data, like Windows. No Kotlin Multiplatform.

## Shape

- A menu-bar app (`LSUIElement`), with a window for Home, History, Settings and Help, and a first-run guide.
- The **pill**: a non-activating, click-through `NSPanel` at the bottom of the screen that shows the voice level, the
  words not typed yet, "Transcribing…", and warnings.
- macOS 13 (Ventura) or later, Apple silicon and Intel.

## How dictation starts and stops

- **Tap Fn** (press and let go) to start, tap it again to finish; **Esc** cancels. A `CGEventTap` on `flagsChanged`
  sees Fn, which needs the **Input Monitoring** permission.
- If macOS is set to do something with Fn (System Settings › Keyboard › "Press 🌐 key to"), the guide asks you to set
  it to "Do Nothing", so Fn doesn't also switch the input source or open the emoji picker. Right Option is offered as
  an alternative.
- A dictation finishes by itself after 10 minutes, so the microphone is never left on.

## Audio and speech

- `AVAudioEngine`, converted to 16 kHz mono; the **Microphone** permission.
- The same models as Windows, each downloaded once and checked against its pinned SHA-256:

| Choice | Model | Engine | Download |
|---|---|---|---|
| English, Live (default) | Kroko streaming (Banafo, CC BY-SA 4.0) + Edge-Punct-Casing | sherpa-onnx | 79 MB |
| English, Standard | NVIDIA Parakeet TDT 110M (CC BY 4.0) | sherpa-onnx | 137 MB |
| English, Accurate | NVIDIA Parakeet TDT 0.6B v2 | sherpa-onnx | 661 MB |
| Hindi + English | Oriserve Whisper Hindi2Hinglish Swift (Apache-2.0) | whisper.cpp (Metal) | 82 MB |
| Hindi + English, Accurate | Oriserve Whisper Hindi2Hinglish Apex | whisper.cpp (Metal) | 874 MB |

- Silero VAD (whisper.cpp's) finds the pauses for Whisper and Parakeet, as on Windows.
- Target on Apple silicon: under 0.3 s per phrase in English.

## Typing into other apps

- **When a dictation starts**, read the focused element with the Accessibility API (`AXUIElement`): its role
  (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`, `AXSecureTextField`), whether it takes line breaks, and
  the text before the cursor (`kAXValueAttribute` + `kAXSelectedTextRangeAttribute`). Mail, Outlook and Spark get
  email layout, and so does webmail in a browser (from the window title).
- **Chrome, Edge and Electron apps** describe their web content only once an assistive app asks (the Mac counterpart of
  the Windows "wake"): set `AXEnhancedUserInterface` (Chrome) or `AXManualAccessibility` (Electron) on the app. To be
  measured on a real Mac.
- **Before each piece is typed**, the same element must still have the focus (`CFEqual` on the `AXUIElement`) and every
  modifier key must be up. Otherwise nothing more is typed and the whole dictation goes to the tap-to-copy notification.
- **Pasting:** save the pasteboard, write the text marked `org.nspasteboard.TransientType` and `ConcealedType` (kept
  out of clipboard managers), check the pasteboard's `changeCount` right before ⌘V (something copied meanwhile is kept,
  and the dictated text is what gets pasted), send ⌘V with `CGEvent` (needs **Accessibility**), then put the
  pasteboard back. Line breaks are the app's new-line keys.
- **Refusals:** never type into an `AXSecureTextField`, or while `IsSecureEventInputEnabled()` is on (a password is
  being typed somewhere).
- **Live typing** as on Windows: finished phrases are typed one pause late, only while the final text still begins with
  them; the phrase being spoken shows in the pill.

## Never lose a dictation, data and privacy

- Notifications (`UNUserNotificationCenter`) for "can't hear you" and "tap to copy".
- History, settings and opt-in samples in `~/Library/Application Support/ThumbFree`, in the same formats as Windows.
  Nothing from password fields; samples never from web browsers.
- Logs hold timings and error names, never your words.

## Distribution

- CI builds an ad-hoc-signed `ThumbFree.app` in a `.dmg` for testing (the first time: right-click › Open).
- A normal install needs Developer ID signing and notarization: the Apple Developer Program, US$99 a year, one account
  for both iPhone and Mac. Then a Homebrew cask.
- Not the Mac App Store: its sandbox blocks global event taps and pasting into other apps.

## Testing

- **GitHub's macOS runners:** the core's unit tests and the shared vectors, the speech engines on the recordings in
  `tests/audio`, and the app build, on every change.
- **A real Mac** for what CI can't do: the microphone, the permissions, Fn, and typing into Notes, Mail, Safari,
  Chrome, Slack, VS Code and Terminal, password fields, and switching apps mid-dictation. A checklist comes with the
  first test build.

## Phases

| Phase | Done when |
|---|---|
| 1. Core in Swift | The shared vectors and the ported unit tests pass on macOS CI |
| 2. Speech engines | Kroko, Parakeet and Whisper with Silero transcribe `tests/audio` on macOS CI |
| 3. App | Menu bar, Fn, microphone, pill, typing with the same-field check, notifications |
| 4. Window and guide | Home, History, Settings, Help, the first-run guide, the word list and dictionary |
| 5. Test builds | A `.dmg` from CI passes the real-Mac checklist |
| 6. Release | Developer ID, notarization, Homebrew |

Then Jarvis for Mac, in mac-voice-assistant.
