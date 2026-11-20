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
- The **menu bar**: the ThumbFree mark (red while recording, dimmed while dictation can't start), and a menu with the
  state, what's missing (a permission, with the System Settings pane that gives it, or the speech model, with its
  download and its progress), the last five dictations to copy, "Copy the text that wasn't typed", "Paste last
  dictation", the dictation language, the speech model and the dictation key (Fn or Right Option), pausing the key,
  Start at login (`SMAppService`), the pill, and Quit. Until the window comes (phase 4), "Open ThumbFree" says where
  things are and opens settings.json.
- The **pill**: a non-activating, click-through `NSPanel` at the bottom of the screen that shows the voice level, the
  words not typed yet, "Transcribing…", and warnings.
- **One copy at a time**, as on Windows: the running copy holds a lock (`flock`) on a file in
  `~/Library/Application Support/ThumbFree`, which macOS lets go of when it quits, however it quits. Opening ThumbFree
  again shows the running copy's menu.
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
- The same models as Windows, each downloaded once into `~/Library/Application Support/ThumbFree/models` and checked
  against its pinned SHA-256 (models Jarvis for Mac already has are used from its folder, read only):

| Choice | Model | Engine | Download |
|---|---|---|---|
| English, Live (default) | Kroko streaming (Banafo, CC BY-SA 4.0) + Edge-Punct-Casing | sherpa-onnx | 79 MB |
| English, Standard | NVIDIA Parakeet TDT 110M (CC BY 4.0) | sherpa-onnx | 137 MB |
| English, Accurate | NVIDIA Parakeet TDT 0.6B v2 | sherpa-onnx | 661 MB |
| Hindi + English | Oriserve Whisper Hindi2Hinglish Swift (Apache-2.0) | whisper.cpp (Metal) | 82 MB |
| Hindi + English, Accurate | Oriserve Whisper Hindi2Hinglish Apex | whisper.cpp (Metal) | 874 MB |

- Silero VAD (whisper.cpp's) finds the pauses for Whisper and Parakeet, as on Windows.
- **Engines,** linked statically: sherpa-onnx 2.0.1 (as on Windows) with ONNX Runtime 1.28.2, and whisper.cpp 1.9.5
  with ggml (Metal and Accelerate). `.github/workflows/engines.yml` builds them from pinned sources into this repo's
  `engines-sherpa-onnx-2.0.1-3` and `engines-whisper-1.9.5-3` releases, which Package.swift pins by checksum.
- **Warm-up:** ggml compiles all its Metal shaders when it's first used, even for Silero, which runs on the CPU: 19–27 s
  on CI's virtual GPU, still to be measured on a real Mac. So when the chosen model uses Silero or Whisper (Parakeet,
  or Hindi + English), the app calls `ThumbFreeSpeech.warmUp()` in the background at launch and when switching to it.
  English Live (Kroko) uses neither, so it doesn't warm up.
- **Notices:** each engine's zip has a notice with the license of everything linked into it (the build checks it
  against the library's symbols), and `scripts/make-app.sh` puts both, with `THIRD-PARTY-NOTICES.md`, in
  `ThumbFree.app/Contents/Resources`.
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
  **Accessibility**), then put the pasteboard back. Line breaks are the app's new-line keys. With `insertMethod`
  "Type" in settings.json, dictations are always typed with key events instead, and the pasteboard is never touched.
- **New-line keys** (`newLineKeys` in settings.json) are found by the app's executable name, which macOS never
  translates (`NSRunningApplication.executableURL`: TextEdit, Microsoft Word, Pages, Code and Xcode get Return, which
  makes a paragraph there), then by its name as macOS shows it. Every other app gets Shift+Return, which chat apps
  take as a line break instead of "send". A settings file brought from Windows keeps Windows' process names
  (`WINWORD`, `notepad`), which no Mac app has: add the Mac names to it.
- **When the clipboard can't be read:** since macOS 15.4 an app's reads of the clipboard can need the user's
  permission (System Settings › Privacy & Security). ThumbFree reads it, to put your copy back, only when that's
  allowed without asking every time. Otherwise, or when the copy can't be read at all, it types the dictation with
  key events and leaves your copy alone. The guide explains the setting.
- **Refusals:** never type into an `AXSecureTextField`, or while `IsSecureEventInputEnabled()` is on (a password is
  being typed somewhere).
- **Live typing** as on Windows: finished phrases are typed one pause late, only while the final text still begins with
  them; the phrase being spoken shows in the pill.

## Never lose a dictation, data and privacy

- Notifications (`UNUserNotificationCenter`) for "can't hear you" and for a dictation that couldn't be typed: the box
  changed, or the typing was refused (ThumbFree isn't allowed to type, Secure Input is on, something else kept being
  copied). Clicking the notification, or its Copy button, copies the dictation, and so does the menu bar's "Copy the
  text that wasn't typed". macOS asks for permission to show them at the first dictation, not at launch.
- **Quitting** while a dictation is being transcribed or typed waits for it, 10 s at most, with the main thread free
  (typing needs it). One still not typed by then is kept, and nothing more of it is typed: it's in History, or, where
  History doesn't keep it, on the pasteboard, which outlives ThumbFree. So is a dictation kept for copying that
  History doesn't have. ThumbFree marks what it puts there as concealed and not copied by you (nspasteboard.org), so
  clipboard managers leave it out of their history, and a notification says where it is. A recording is cancelled, as
  on Windows; the dictation key does nothing while ThumbFree waits, and quitting again, or logging out, waits for the
  same answer.
- Settings are in `~/Library/Application Support/ThumbFree/settings.json`. **History** (`history.txt`) and opt-in
  **samples** (`samples/`) are in `~/Library/Application Support/ThumbFree/Dictations.noindex`, in the same formats as
  Windows. The folder is named that way so that Spotlight never indexes the text of your dictations: Spotlight leaves
  out any folder whose name ends in `.noindex`, while a `.metadata_never_index` file no longer keeps it out of a folder
  on recent macOS (Eclectic Light, tested on Sequoia and Tahoe), and `~/Library/Application Support` itself is indexed.
  Windows marks history.txt "not content indexed" for the same reason.
- Nothing from password fields; samples never from web browsers. **History leaves out private browser windows**, and
  any browser window that can't be told apart from one, from the window's title as the Accessibility API reads it
  (`PrivateWindows`). A browser window whose text box or title can't be read counts as private. What each browser's
  sources say:
  - Chrome, Chromium and Brave: the AXTitle is the window's accessible title, "<page> - Google Chrome" with
    " (Incognito)" (Brave: " (Private)", Tor windows too) or " (Guest)" added, in the browser's language; ThumbFree
    knows every language they ship.
  - Firefox: "<page> — Private Browsing" on macOS, in every language it ships. "Never remember history" makes every
    window private without saying so, so ThumbFree reads that setting in Firefox's profiles. An administrator can do
    the same where the profiles never show it, so ThumbFree also reads the app's `distribution/policies.json`, the
    macOS preferences for its bundle identifier (configuration profiles, `defaults`), and AutoConfig's `.cfg` file. One
    of those files that can't be read, or a `.cfg` that loads more from a server, counts as private.
  - Tor Browser and Mullvad Browser are always private.
  - Safari's private windows have the same titles as the others, and no other signal is known to be reliable, so
    Safari's dictations aren't kept in History, nor those of the other browsers whose private windows can't be told
    apart yet: Edge (its strings are closed, so its title can't be checked without a Mac), Arc, Opera, Vivaldi,
    DuckDuckGo, Orion, the Chromium and Firefox forks, and any other app that opens web links. A real-Mac check can
    move a browser to the list above.
- Logs, in `~/Library/Logs/ThumbFree`, hold timings and error names, never your words or window titles.

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
  Chrome, Slack, VS Code and Terminal, password fields, and switching apps mid-dictation. How to install a test build,
  and the checklist, are in [mac-testing.md](mac-testing.md).

## Phases

| Phase | Done when | Status (November 2026) |
|---|---|---|
| 1. Core in Swift | The shared vectors and the ported unit tests pass on macOS CI | Done |
| 2. Speech engines | Kroko, Parakeet and Whisper with Silero transcribe `tests/audio` on macOS CI | Done |
| 3. App | Menu bar, Fn, microphone, pill, typing with the same-field check, notifications | In, and tested on CI: the dictation host, the menu bar, notifications, model downloads, sounds, one copy at a time, and the parts (Fn, the microphone, the permissions, reading the box, typing, the pill). Next: the real-Mac checklist in PR #9 |
| 4. Window and guide | Home, History, Settings, Help, the first-run guide, the word list and dictionary | |
| 5. Test builds | A `.dmg` from CI passes the real-Mac checklist | CI builds the `.dmg`; the checklists are in PRs #1, #2 and #4 |
| 6. Release | Developer ID, notarization, Homebrew | |

Then Jarvis for Mac, in mac-voice-assistant. Its idea board is already ported, and its core is being ported.
