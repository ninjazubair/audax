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

AUDAX has one window with a sidebar:

- **Home**: live state, your shortcuts, a Try-it box, and only the setup items that need you.
- **History**: every dictation, searchable, with Copy (also logged as JSON lines in
  `~/.cache/mac-dictation/dictation.log`).
- **Dictation** (⌘,): change either shortcut (click the field, press the keys), sounds,
  language (English or German), clean-up level (Off, Light or Full; Full also fixes grammar).
- **AI Provider**: the clean-up step's provider — Local Ollama (default; text stays on the
  Mac), GitHub Copilot (your existing seat through the GitHub CLI; pick any model your seat
  offers), Claude API, OpenAI API, Amazon Bedrock (API key, access key or AWS profile),
  Microsoft Foundry, or any OpenAI- or Anthropic-compatible gateway. Keys are stored in the
  macOS Keychain; **Test connection** sends one tiny request.
- **Words**: your own corrections (misspelled → correct), applied to every dictation.

### Optional `.env` file

Power users and IT can set the provider in `~/.config/audax/.env` (AI Provider → Open .env file
creates a commented template). Values there override Settings, key by key: `AUDAX_PROVIDER`,
`AUDAX_MODEL`, `AUDAX_BASE_URL`, `AUDAX_API_KEY`, `AUDAX_AUTH_HEADER`, `AUDAX_API_VERSION`,
`AWS_REGION`, `AWS_BEARER_TOKEN_BEDROCK`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
`AWS_SESSION_TOKEN`, `AWS_PROFILE`, `AZURE_OPENAI_ENDPOINT` / `AZURE_OPENAI_API_KEY` /
`AZURE_OPENAI_API_VERSION`. `OPENAI_API_KEY` is used only for OpenAI and `ANTHROPIC_API_KEY`
only for Claude; gateways take `AUDAX_API_KEY`. Keep the file private (`chmod 600`); AUDAX
warns when it is not and never edits it.

Measured on the developer's Apple Silicon Mac: speech recognition about 0.15 s; clean-up about
0.3 s with local Ollama, 2–5 s with a cloud model (Copilot gpt-4.1 ≈2 s, gpt-6.1-sol 2.7–4.9 s).

## Privacy

Audio never leaves the Mac. With Local Ollama, the text doesn't either. With any other provider
selected, the transcribed text is sent to that provider for clean-up; AUDAX says where. API
keys and tokens are never written to the log. If a provider fails, AUDAX pastes the raw transcript and says "Pasted without
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
