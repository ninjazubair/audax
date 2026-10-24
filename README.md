# AUDAX

Push-to-talk dictation for macOS. Hold a key, speak, let go: the text appears in whatever app
you were typing in. Speech recognition runs on your Mac (whisper.cpp on the Apple GPU); an
optional clean-up step fixes punctuation, filler words and grammar.

## Install

1. Open the DMG from the latest release and drag **AUDAX** to Applications.
2. The app is self-signed, not notarised by Apple. The first time, **right-click AUDAX →
   Open → Open**. After that it opens normally.
3. On first launch AUDAX opens a setup window in Terminal. It installs whisper.cpp and Ollama
   with Homebrew and downloads the speech model (574 MB) and the local clean-up model. Needs an
   Apple Silicon Mac and Homebrew.
4. Allow **Microphone** and **Accessibility** when asked (Accessibility lets AUDAX paste the
   text and use the Fn key).
5. System Settings → Keyboard → **"Press 🌐 key to" → Do Nothing**. Otherwise macOS also reacts
   every time you press Fn.

## Use

| Action | Default |
| --- | --- |
| Talk | Hold **Fn**, speak, release |
| Hands-free | Hold Fn, tap **Space** to lock, release; press **Fn Space** to finish |
| Cancel | Press any other key while holding Fn |

Both shortcuts can be changed in **Settings** (⌘,): click the field and press the keys.

Settings also has:

- **Language**: English or German.
- **Clean-up**: Off, Light (punctuation, fillers, self-corrections) or Full (also grammar).
- **Provider** for the clean-up step: Local Ollama (default; text stays on the Mac), GitHub
  Copilot (uses your existing Copilot seat through the GitHub CLI; pick any model your seat
  offers), Claude API or OpenAI API (API key stored in the macOS Keychain).
- **Words**: your own corrections (misspelled → correct), applied to every dictation.

Every dictation is listed in the main window with a Copy button, and logged as JSON lines in
`~/.cache/mac-dictation/dictation.log`.

Measured on the developer's Apple Silicon Mac: speech recognition about 0.15 s; clean-up about
0.3 s with local Ollama, 2–5 s with a cloud model (Copilot gpt-4.1 ≈2 s, gpt-6.1-sol 2.7–4.9 s).

## Privacy

Audio never leaves the Mac. With Local Ollama, the text doesn't either. With Copilot, Claude or
OpenAI selected, the transcribed text is sent to that provider for clean-up; the window footer
says so. If a provider fails, AUDAX pastes the raw transcript and says "Pasted without
clean-up".

## Build from source

```bash
./build.sh            # builds and signs AUDAX.app, writes dist/<timestamp>/AUDAX-<version>.dmg
./build.sh --install  # the same, then replaces /Applications/AUDAX.app and opens it
/usr/bin/python3 test_dictate.py && /usr/bin/python3 test_providers.py   # each prints "ok"
```

`build.sh` creates a self-signed code-signing identity ("AUDAX Local Signing") in your login
keychain on first run, so macOS keeps the Microphone and Accessibility grants across rebuilds.
Requires Xcode command-line tools and macOS 14 or later.

Design notes and plans: `docs/superpowers/specs/` and `docs/superpowers/plans/`.
