# Testing ThumbFree on a real Mac

GitHub's Macs build ThumbFree and run its 400-odd tests on every change, but they have no microphone, no keyboard and
nobody to grant permissions. This page is for a person with a Mac: how to install a test build, and what to check.
Tick what works, and report what doesn't (see the end).

## Install a test build

1. **Get the `.dmg`.** On GitHub, open the repo's **Actions** tab, choose the **App** workflow, open its latest run on
   `main`, and download the **ThumbFree-dmg** artifact (a zip with the `.dmg` inside). It's a universal build, for
   Apple silicon and Intel Macs, macOS 13 or later.
2. **Install it.** Open the `.dmg` and drag ThumbFree to Applications.
3. **Open it the first time.** Test builds aren't signed by Apple yet, so macOS blocks them: open ThumbFree once, then
   go to System Settings › Privacy & Security and choose **Open Anyway**. (Right-click › Open no longer works on
   macOS 15 and later.)
4. **Permissions.** ThumbFree's menu-bar menu lists what's missing: the microphone, and Accessibility (to read the box
   you're typing in and to paste into it). Each item opens the right page of System Settings.
5. **Each new test build** needs its permissions given again, because a test build's signature changes every time. If
   Accessibility looks on but ThumbFree says it's missing, remove ThumbFree from the list, or run
   `tccutil reset Accessibility app.thumbfree.mac`, then turn it on again.
6. **If Fn already does something** (System Settings › Keyboard › "Press 🌐 key to"), set it to **Do Nothing**, or
   choose Right Option as the dictation key in ThumbFree's menu.

## Checklist

### First run and permissions

- [ ] The `.dmg` opens with Open Anyway; ThumbFree's mark appears in the menu bar (no Dock icon); its menu says what's
  missing.
- [ ] "Allow the microphone…" shows macOS's prompt the first time, then opens Privacy & Security › Microphone. "Allow
  ThumbFree to type (Accessibility)…" opens Accessibility. Once allowed, the items go and the state says Ready within a
  few seconds, without a restart.
- [ ] With no model yet, the pill says to download one; "Download the speech model (English, live, 79 MB)" shows
  progress in the menu, Cancel works, and the pill says when it's ready. A big model (English, accurate) asks first.
- [ ] If Accessibility was given by your organisation's device management, does typing still work?
- [ ] Opening ThumbFree.app again (or `open -n ThumbFree.app`) opens the running copy's menu, and the second copy quits.
- [ ] Start at login works (it may need approval in System Settings › General › Login Items).

### The dictation key

- [ ] **Fn:** tap, speak, tap. Esc cancels, and the app you're in doesn't get the Esc. Try a MacBook keyboard and, if
  you have one, a Magic Keyboard with 🌐.
- [ ] Fn shortcuts never start dictation: Fn+arrows, Fn+Delete, Fn+E, Fn+Control+arrows, Fn+F-keys (with both F-key
  settings).
- [ ] **Right Option** (chosen in the menu) works the same; Option+letter (é), Option-click, a Finder Option-drag and
  Option-scroll don't start dictation.
- [ ] In a password field, or with Terminal's Secure Keyboard Entry on (even in the background), a tap makes the pill
  say "Secure Input is on, so dictation can't start", and Fn+Delete or Fn+arrows there never start dictation. On the
  lock screen too.
- [ ] Holding Fn while live typing pastes doesn't confuse the key; Fn+Esc while recording keeps recording.
- [ ] No keyboard lag. Trackpad scrolling and drags stay smooth. After sleep and wake, the key still works.
- [ ] Switching users with Fn held leaves no stuck keys.
- [ ] Turning Accessibility off while ThumbFree runs: the keyboard keeps working normally.

### The microphone

- [ ] The built-in microphone, a USB one and AirPods. AirPods may restart the recording once when they connect; it must
  not keep restarting, and their first second must not trigger "can't hear you".
- [ ] Switching the input in System Settings mid-dictation carries on with the new one, including between two inputs of
  the same kind. Unplugging an external microphone moves to the built-in one.
- [ ] Changing the input's sample rate in Audio MIDI Setup mid-dictation; input and output at different rates.
- [ ] An audio interface with the microphone on input 1 of 2 (it reads quieter: does recognition still work?).
- [ ] The level in the pill looks right (speech fills about half to three-quarters).
- [ ] "ThumbFree can't hear you" shows when another app takes the microphone, and goes when sound comes back.

### Typing into apps

- [ ] Dictate with live typing into Notes, TextEdit, Mail, Safari, Chrome, Slack, VS Code and Terminal. The text lands
  in the box you started in, after a space when there's text before the cursor.
- [ ] Chrome or Slack just brought to the front: a dictation started straight away still lands in the right box, and
  moving to another box of the same page mid-dictation stops the typing (the dictation is kept to copy).
- [ ] Spotlight, Alfred or Raycast, and a notification's reply box: the text arrives.
- [ ] "New line" gives a paragraph in TextEdit, Word, Pages, VS Code and Xcode, and a line break (not a send) in Slack
  and Messages. In Notes and Mail: is the line break what you'd expect?
- [ ] A two-line dictation has no one-second pause between the lines.
- [ ] Keyboard layouts: Dvorak, "Dvorak – QWERTY ⌘" and Russian paste correctly, including after switching the layout
  while another app is in front.
- [ ] Password fields are never typed into: Safari's and Chrome's sign-in boxes, System Settings' password boxes.
- [ ] Terminal with a long scrollback: dictation still starts quickly.
- [ ] Firefox and a Java app: the box is found.
- [ ] Window managers (Rectangle, Magnet) still move Chrome's windows smoothly after ThumbFree has talked to Chrome.

### The clipboard

- [ ] After a dictation, what you had copied before is back. Clipboard managers (Maccy, Paste, Raycast, Alfred) don't
  list the dictated text, and an iPhone doesn't offer it (Universal Clipboard).
- [ ] Something copied while a dictation is being typed is kept.
- [ ] macOS's clipboard-privacy prompt (macOS 15.4 and later): does the first dictation show one? With Don't Allow,
  your copy survives and the dictation is typed with keys instead.
- [ ] Typing with keys (also `"insertMethod": "Type"` in settings.json): accents, emoji, line breaks, Terminal;
  Japanese, Chinese and Korean input sources; a virtual machine or remote desktop app; does autocorrect, smart quotes,
  or Slack's `:` and `@` change the text?

### Never losing a dictation

- [ ] Switching apps or boxes mid-dictation types nothing more, and the notification ("Your dictation is safe") copies
  the whole dictation, from a click and from its Copy button. "Copy the text that wasn't typed" in the menu does the
  same. With notifications off for ThumbFree, the pill names only the menu's item.
- [ ] Notifications: permission is asked at the first dictation, not at launch.
- [ ] Quit right after finishing a long dictation with a slow model (English, accurate): the dictation is typed, then
  ThumbFree quits. Choosing Quit again meanwhile changes nothing, and a tap of the key starts nothing.
- [ ] Choose Quit while a dictation finishes, then log out straight away: the logout isn't cancelled.
- [ ] With History off (or from a private window), a dictation waiting in "Copy the text that wasn't typed": after Quit
  it's on the clipboard, ⌘V pastes it, and clipboard managers don't list it.

### History and privacy

- [ ] Nothing from password fields appears in History.
- [ ] `mdfind` doesn't find dictated text (search for a word you dictated, a few minutes later).
- [ ] Private windows keep nothing in History. Accessibility Inspector (in Xcode's developer tools) shows a window's
  AXTitle:
  - [ ] Chrome: the brand ("Google Chrome") is in a normal window's AXTitle and an Incognito one's, and " (Incognito)"
    only in the latter. Incognito and Guest windows keep nothing; normal windows are kept. Ideally once in another
    language too.
  - [ ] Brave: Private windows (and Private with Tor) keep nothing; normal windows are kept.
  - [ ] Firefox: private windows keep nothing; normal ones are kept; with "Never remember history", nothing is kept.
  - [ ] Safari: nothing is kept from any window (private windows can't be told apart yet). With Accessibility
    Inspector, look for anything that marks a private window, such as a "Private" label in the title or tab bar.
  - [ ] Edge: nothing is kept. Read an InPrivate window's AXTitle: if it says InPrivate, Edge can follow Chrome's rule.
- [ ] Opt-in samples (if you turn them on) are never kept from a browser.

### Speech

- [ ] English (live) is typed within a moment of each pause. How long does a phrase take with English (standard) and
  English (accurate)?
- [ ] Hindi + English: the first dictation after launch waits while ThumbFree prepares the graphics chip (19–27 s on
  GitHub's virtual Macs). How long on yours, and does it happen in the background before you dictate?
- [ ] "Send me the latest build logs" and "GitHub Copilot" come out right.

### The rest

- [ ] The start and stop sounds are short and quiet; `"soundFeedback": false` in settings.json silences them.
- [ ] With Jarvis for Mac running and the key on Fn, the menu and the pill warn.
- [ ] The menu's recent dictations copy when clicked; "Pause dictation keys" stops the key; "Always show status pill"
  keeps the pill up.

## Reporting a problem

Open an issue in this repo with the checklist item, what you expected, what happened, your Mac (model, Apple silicon
or Intel) and macOS version, and the build (the App workflow run). ThumbFree's logs are in `~/Library/Logs/ThumbFree`
and never contain your words; attach the latest one. Settings are in
`~/Library/Application Support/ThumbFree/settings.json`.

The checklists in pull requests #1, #2, #4 and #9 have more detail behind each item.
