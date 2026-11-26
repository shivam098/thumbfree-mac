# Agent instructions

ThumbFree for Mac: tap Fn and type with your voice in any app, with private, on-device dictation. It's a Swift package
for macOS 13 and later (ThumbFreeCore, ThumbFreeSpeech, ThumbFreeMac, ThumbFreeApp and the ThumbFree app). Jarvis for
Mac (shivam098/mac-voice-assistant) uses its libraries.

**On a real Mac?** Start with [docs/HANDOFF-mac.md](docs/HANDOFF-mac.md): where the project stands, and how to finish
testing and set the app up.

- Build and test: `swift build -c release` and `swift test`. For the engine tests' models, see docs/HANDOFF-mac.md,
  section 3. Build the app with `scripts/make-app.sh`.
- The design and its phases are in docs/mac.md; the real-Mac checklist is docs/mac-testing.md.
- Commit as `shivam098 <39924466+shivam098@users.noreply.github.com>`.
- One PR per change, with CI green and an independent review before merging (squash). PR descriptions start with the
  owner's Agent assessment block (docs/HANDOFF-mac.md, section 7).
