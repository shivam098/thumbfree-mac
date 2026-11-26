# Handoff: finishing on a real Mac

For whoever picks this up on a Mac: a person, or a coding agent started in this repo (AGENTS.md points here). Work
through it in order: check where things stand, set up the Mac, build and test, install and set up the app, run the
checks only a real Mac can do, then report what you found.

Written on 26 November 2026 on a Windows PC with no Mac. Until now ThumbFree for Mac has been built and tested only on
GitHub's macOS runners, which have no microphone, no keyboard and nobody to grant permissions.

## 1. Where things stand

ThumbFree for Mac: tap Fn (or Right Option), speak, tap again, and your words are typed into whatever app you're in.
Speech is recognised on the Mac; nothing goes online except model downloads. It's a port of the Windows app
(shivam098/thumbfree-windows) and shares its test data (`tests/vectors`, `tests/audio`). docs/mac.md is the design and
has the phase table.

Done and merged (main was `fe720149` when this was written):

- **Phase 1, the core in Swift:** formatting, emails, lists and corrections, live typing, field rules and the word list,
  held to the shared test vectors.
- **Phase 2, the speech engines:** sherpa-onnx (Kroko live English, Parakeet) and whisper.cpp (Hindi + English) as
  static xcframeworks, built by `.github/workflows/engines.yml` and published as this repo's `engines-*` pre-releases.
  The models come from Hugging Face and the `models-*` pre-releases.
- **Phase 3, the app, tested on CI only:** the menu bar, the Fn or Right Option key, the microphone, the permissions,
  reading the text box (Accessibility), typing into it (pasteboard and ⌘V, or key events), the pill, notifications,
  model downloads, sounds, History and samples, one copy at a time, and start at login.
- **Test builds:** every push to main builds `ThumbFree-<version>.dmg` (universal, signed ad hoc) as the
  **ThumbFree-dmg** artifact of the **App** workflow. No app release has been published yet.
- **docs/mac-testing.md:** how to install a test build, and the full checklist for a real Mac.

Not done yet:

- **Phase 4, the window:** Home, History, Settings, Help, the first-run guide, the word list and the dictionary. The
  menu bar is the only UI so far.
- **Phase 5, a test build that passes the real-Mac checklist.** This is the work for this Mac.
- **Phase 6, the release:** Developer ID signing, notarization and Homebrew (see section 8).

Open work: PR #12 (Whisper options for Jarvis's standby check), opened from the Windows PC. Jarvis for Mac
(shivam098/mac-voice-assistant) uses this package's libraries (ThumbFreeCore, ThumbFreeMac and ThumbFreeSpeech) at the
tip of main, and its CI builds against them every day. Don't change their public API without checking that Jarvis still
builds.

Before you start, see what has changed since this was written:

```sh
git pull
gh pr list
gh run list --branch main --limit 3
```

## 2. Set up this Mac

- **To run the app:** macOS 13 or later, on Apple silicon or Intel.
- **To build it:** Xcode 16 with Swift 6.1 or later. CI uses Xcode 16.4 on macOS 15. Install Xcode from the App
  Store, open it once to finish installing, then:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  xcodebuild -version
  swift --version
  ```

- **GitHub:** the GitHub CLI, signed in as shivam098, then the clone and the identity for commits:

  ```sh
  brew install gh          # or the installer from https://cli.github.com
  gh auth login
  gh repo clone shivam098/thumbfree-mac
  cd thumbfree-mac
  git config user.name shivam098
  git config user.email 39924466+shivam098@users.noreply.github.com
  ```

## 3. Build and test

```sh
swift build -c release
swift test
```

- The first build downloads the two speech engines (the xcframework zips in this repo's `engines-*` releases), and
  SwiftPM checks their checksums.
- On CI, `swift test` runs about 430 tests with no failures. The engine tests skip a model that isn't there. To run them
  too, download the models into `models/` the way CI's "Speech models (download)" step does
  (.github/workflows/ci.yml), then:

  ```sh
  THUMBFREE_MODELS="$PWD/models" swift test
  ```

- Anything that fails here but passes on CI is a finding: write it down (section 6).

## 4. Install and set up the app

1. **Get the app.** Either build it here:

   ```sh
   scripts/make-app.sh      # dist/ThumbFree.app and dist/ThumbFree-0.1.0.dmg
   ```

   or download the .dmg CI built from the latest App run on main:

   ```sh
   gh run list --workflow App --branch main --limit 1
   gh run download <run id> -n ThumbFree-dmg
   ```

2. **Install it** as docs/mac-testing.md, "Install a test build", says: drag ThumbFree to Applications. The first time,
   open it, then choose System Settings › Privacy & Security › **Open Anyway**. Give the microphone and Accessibility
   when its menu asks. Each new test build needs Accessibility given again, because its ad-hoc signature changes; if it
   looks on but ThumbFree says it's missing, run `tccutil reset Accessibility app.thumbfree.mac` and turn it on again.
3. **Its files:** settings, History, samples and models are in `~/Library/Application Support/ThumbFree`; the logs are
   in `~/Library/Logs/ThumbFree`, where Console finds them.
4. **Jarvis for Mac** uses Fn too. Run one of the two at a time; each warns while the other is running.

## 5. What only a real Mac can check

Go through docs/mac-testing.md's checklist, every section: first run and permissions, the dictation key, the
microphone, typing into apps, the clipboard, never losing a dictation, History and privacy, speech, and the rest. Some
of it needs a person (speaking, other keyboards, AirPods). An agent can do the parts that don't, and ask the owner to
do the rest.

The reviews on CI left these open. Most are in the checklist too; take extra care with them:

1. Whether the Fn key needs Input Monitoring, or only Accessibility (not in the checklist yet).
2. macOS's clipboard-privacy prompt (macOS 15.4 and later): does the first dictation show one? With Don't Allow, your
   copy must survive and the dictation be typed with keys instead.
3. History and private windows: Chrome, Brave and Firefox private windows are recognised and keep nothing. Safari and
   Edge dictations are never kept at all, because their private windows can't be told apart yet; the checklist says
   what to look for in Accessibility Inspector so they can be.
4. VoiceOver reads the menu bar icon as "ThumbFree" (not in the checklist yet).
5. Keyboard layouts: Dvorak, "Dvorak – QWERTY ⌘" and Russian paste correctly (try AZERTY too, if you can).
6. Model downloads from Hugging Face and GitHub's releases, which redirect, finish and pass their checks.
7. Hindi + English: the first dictation after launch waits while ThumbFree prepares the graphics chip (19–27 s on
   GitHub's virtual Macs). How long does it take on this Mac, and does it happen in the background before you dictate?

## 6. Report what you found

- **Results:** write `docs/test-results/<YYYY-MM-DD>-<Mac model>.md` with the Mac model and chip, the macOS version, the
  keyboard, the build you tested (a commit, or the App run's id), and each checklist line as pass, fail (with what
  happened) or not tried. Open a PR with it.
- **Problems:** open one GitHub issue per problem, with the steps, what should have happened, what happened, the Mac
  model and macOS version, and the relevant lines from `~/Library/Logs/ThumbFree`. The logs never contain your words,
  but read them before attaching. Label the issues `real-mac` (create the label if it doesn't exist).
- **Fixes:** fix only what is clearly broken, each fix in its own PR, with a test where one can be written.
- **Done:** when the checklist passes, update the phase table in docs/mac.md.

## 7. Rules for agents working here

- One change per PR. CI green and an independent review (for example a code-review agent) before merging, then
  squash-merge.
- PR descriptions start with the owner's Agent assessment block: between `<!-- copilot-assessment:v1 -->` and
  `<!-- /copilot-assessment -->`, a "### Agent assessment" heading, the line "Self-reported assessment, not an
  independent review.", "Assessed revision:" with the full head commit SHA, and a table scoring Change confidence out
  of 10 (bug fixes also score Diagnosis confidence and Evidence fit). Each score's rationale lists evidence items,
  marked ↑ (supports it) or ↓ (missing, unverified or against it).
- Commit as `shivam098 <39924466+shivam098@users.noreply.github.com>`.
- Never commit secrets, models or build output (`models/`, `dist/` and `.build/` are ignored).
- Behave as the Windows app does unless there's a Mac reason not to, and say why in the PR.
- Don't build a reduced version of a feature, or add security measures nobody asked for, without asking the owner.
  State measurements as findings, and ask the owner before drawing conclusions from them.
- Don't publish a release without the owner's go-ahead.

## 8. Decisions waiting for the owner

- **A first release:** publish the test build as a GitHub pre-release (v0.1.0) once the checklist passes? Nothing has
  been released yet.
- **Signing:** Developer ID signing and notarization (phase 6) need a paid Apple Developer account. Until then, every
  build needs Open Anyway and its permissions given again.
- **Safari and Edge in History:** their dictations aren't kept (section 5, item 3). Keep that, or recognise their
  private windows, if testing finds a reliable sign?
