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

- **Tap Fn** (press and let go) to start, tap it again to finish; **Esc** cancels. Dictation starts when Fn is let
  go, so a Fn shortcut (Fn+Delete, Fn+arrows, Fn+E) never turns the microphone on.
- A `CGEventTap` sees Fn. With the **Accessibility** permission, which typing needs anyway, the tap also keeps Esc
  from reaching the app; with only **Input Monitoring**, it sees Fn and Esc still cancels, but the app gets the Esc
  too. To be confirmed on a real Mac.
- While **Secure Input** is on (a password field, Terminal's Secure Keyboard Entry, some password managers), macOS
  hides the other keys from ThumbFree, so a Fn shortcut can't be told from a tap. A press of Fn then never starts
  dictation, and the pill says why; a tap still finishes a dictation already recording.
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
  the 2,000 characters before the cursor (`kAXSelectedTextRangeAttribute`, then that range only, so a long document
  or Terminal's scrollback isn't copied each time). Mail, Outlook and Spark get email layout, and so does webmail in a
  browser (from the window title).
- **The box's app is the app taking the keys** (`kAXFocusedApplicationAttribute`), which isn't always the app in
  front: Spotlight's box and a notification's reply take the keys while the app behind stays in front, and Safari's
  pages are described by a WebKit helper process.
- **Chrome, Edge and Electron apps** describe their web content only once an assistive app asks (the Mac counterpart of
  the Windows "wake"): set `AXEnhancedUserInterface` (Chrome) or `AXManualAccessibility` (Electron) on the app. They
  wait 2 s before doing it, so ThumbFree asks when such an app comes to the front, not when a dictation starts; a box
  still undescribed at the start is read again just before the first piece is typed.
- **Before each piece is typed**, the same element must still have the focus (`CFEqual` on the `AXUIElement`) and every
  modifier key must be physically up. Otherwise nothing more is typed and the whole dictation goes to the tap-to-copy
  notification.
- **Pasting:** save the pasteboard, write the text marked `org.nspasteboard.TransientType`, `ConcealedType` and
  `AutoGeneratedType` (kept out of clipboard managers) and for this Mac only (not Universal Clipboard), check the
  pasteboard's `changeCount` right before ⌘V (something copied meanwhile is kept, and the dictated text is what gets
  pasted), send ⌘V with `CGEvent` using the key that types "v" in the current keyboard layout (needs
  **Accessibility**), then put the pasteboard back. Line breaks are the app's new-line keys.
- **When the clipboard can't be read:** since macOS 15.4 an app's reads of the clipboard can need the user's
  permission (System Settings › Privacy & Security). ThumbFree reads it, to put your copy back, only when that's
  allowed without asking every time. Otherwise, or when the copy can't be read at all, it types the dictation with
  key events and leaves your copy alone. The guide explains the setting.
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

- On every change, CI builds an ad-hoc-signed, universal `ThumbFree.app` in a `.dmg` for testing (`scripts/make-app.sh`;
  the App workflow's artifact). macOS 15 and later block it the first time: try to open it, then choose System
  Settings › Privacy & Security › Open Anyway. Each test build needs its permissions given again, because an ad-hoc
  signature changes with every build.
- A normal install needs Developer ID signing and notarization: the Apple Developer Program, US$99 a year, one account
  for both iPhone and Mac. With the hardened runtime that notarization requires, the app also needs the
  `com.apple.security.device.audio-input` entitlement for the microphone. Then a Homebrew cask.
- Not the Mac App Store: its sandbox blocks global event taps and pasting into other apps.

## Testing

- **GitHub's macOS runners:** the core's unit tests and the shared vectors, the speech engines on the recordings in
  `tests/audio`, and the app build, on every change.
- **A real Mac** for what CI can't do: the microphone, the permissions, Fn, and typing into Notes, Mail, Safari,
  Chrome, Slack, VS Code and Terminal, password fields, and switching apps mid-dictation. A checklist comes with the
  first test build.

## Phases

| Phase | Done when | Status (November 2026) |
|---|---|---|
| 1. Core in Swift | The shared vectors and the ported unit tests pass on macOS CI | Done |
| 2. Speech engines | Kroko, Parakeet and Whisper with Silero transcribe `tests/audio` on macOS CI | In review |
| 3. App | Menu bar, Fn, microphone, pill, typing with the same-field check, notifications | The parts are in: Fn, the microphone, the permissions, reading the box, typing, the pill. Next: the dictation host and the menu bar |
| 4. Window and guide | Home, History, Settings, Help, the first-run guide, the word list and dictionary | |
| 5. Test builds | A `.dmg` from CI passes the real-Mac checklist | CI builds the `.dmg`; the checklists are in PRs #1, #2 and #4 |
| 6. Release | Developer ID, notarization, Homebrew | |

Then Jarvis for Mac, in mac-voice-assistant. Its idea board is already ported, and its core is being ported.
