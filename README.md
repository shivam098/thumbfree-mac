# ThumbFree for Mac

**Type with your voice, not your thumbs. 100% offline.**

Tap **Fn (🌐)**, speak, and tap it again: your words are typed into whatever app you're using, cleaned up and
punctuated. Speech is recognised on your Mac; nothing you say is uploaded, and there's no account.

**Status: in development.** There's nothing to install yet. The design and the plan are in [docs/mac.md](docs/mac.md).

ThumbFree also runs on [Android](https://github.com/shivam098/thumbfree-android) and
[Windows](https://github.com/shivam098/thumbfree-windows), and an [iPhone](https://github.com/shivam098/thumbfree-ios)
version is planned. Every app follows the same feature reference:
[PLAN.md, section 3](https://github.com/shivam098/thumbfree-android/blob/main/docs/PLAN.md#3-feature-reference-built-on-android-copy-to-every-platform).

## What it will do

- **Tap, talk, tap.** With live typing, each phrase is typed as soon as you've moved on to the next one; the words not
  typed yet show in a small pill at the bottom of the screen.
- **Writes like you meant to:** filler words ("um", "you know", "thik hai na") and repeats are left out, punctuation
  is added, and spoken punctuation works ("comma", "new line").
- **Emails and lists, laid out for you,** and "Friday at 3 pm… actually 4 pm" keeps only the correction.
- **English and Hindi + English,** on the same models as Windows: Kroko for live English, NVIDIA Parakeet, and
  Oriserve's Whisper models for Hinglish.
- **Only where you are:** text goes only into the box you started in. If you've moved somewhere else, nothing more is
  typed, and a notification keeps the whole dictation for you to copy. Password fields are never typed into.
- **History** of the last 30 days, on your Mac only, plus "words I use often" and a personal dictionary.

## Jarvis

Jarvis, the voice assistant (dictation plus "Hey Jarvis" voice commands and the AI brain), comes to the Mac next as its
own app, in [mac-voice-assistant](https://github.com/shivam098/mac-voice-assistant), built on this repo's Mac engine.
Both apps use Fn, so run one at a time; each one tells you if the other is running.

## Test data

`tests/vectors` (how each test sentence must come out) and `tests/audio` (speech recordings) are the same files in
every ThumbFree repo. The **Test data in sync** check fails while this copy differs from the others: when you change
one, copy the change to all four repos.
