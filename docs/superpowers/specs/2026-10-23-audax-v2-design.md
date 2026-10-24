# AUDAX v2 — design

Date: 2026-10-23. Owner: Zubair. Written from a dictated request (23 Oct), the live app, the
code and the dictation log. Decisions marked **(my call)** were made by the implementer because
the owner asked for no further questions; everything else is the owner's words.

## Intent

AUDAX is a macOS menu-bar dictation app: press a shortcut, talk, the text lands where you were
typing. v2 fixes the three things that made v1 feel broken, and adds the settings the owner asked
for, in this priority order:

1. It must work every time and feel fast; the end sound must be pleasant.
2. Shortcuts the user sets by pressing the keys.
3. A user-maintained list of misspelling → correct word.
4. A log of everything spoken (already exists; keep it).
5. Grammatically clean output.
6. Choice of model: local Ollama (today), GitHub Copilot via the user's existing subscription
   (as Amber does), Claude API key, OpenAI API key.
7. German as a selectable language next to English (a setting, no auto-detect).

## What was measured (sources: `~/.cache/mac-dictation/dictation.log`, 17 dictations 21–23 Oct;
code read 23 Oct)

- Processing time is not the problem: median 1.4 s end to end (STT 0.8 s, clean-up 0.3 s),
  worst 5.5 s after long idle gaps (cold model loads).
- The felt delay and the "shortcut did nothing" come from silence detection: the voice detector
  calibrates "room noise" from the first sound it hears (`AUDAX.swift:182-185`); speaking at once
  makes the voice the baseline, so the app waits the full 8 s give-up and reports nothing heard.
- The end sound is two chimes in a row (`chime.stop()` then `chime.done()`).
- Clean-up today is local Ollama `gemma4` via `dictate.py`; there is no Copilot in AUDAX. Amber
  uses the GitHub CLI (`gh auth token`) and sends that token to the Copilot API; validated live
  23 Oct for `zuhussai_adobe`: Copilot Business, chat enabled, API host
  `https://api.business.githubcopilot.com`.
- gemma4 cleans German correctly when told to keep the language (tested 23 Oct, 1.0 s).

## Decisions

### Recording (owner)
- **No silence detection.** Hold the talk shortcut to record; releasing it finishes. A second,
  hands-free shortcut starts recording on press and finishes on the next press.
- A 5-minute safety cap remains **(my call)**. Recordings shorter than 0.3 s are "Didn't catch
  that" **(my call)**.
- Defaults **(my call)**: talk = ⌃⌥D (unchanged), hands-free = ⌃⌥Space.

### Shortcuts (owner)
- Both shortcuts are set in Settings by clicking a field and pressing the keys. Stored and
  re-registered immediately; the UI text everywhere shows the current keys.
- A shortcut must include ⌃ or ⌥ (⇧-only and ⌘-only combos are rejected: a global ⇧D or ⌘W would
  steal that key from every app), and the two must differ **(my call)**.

### Sounds (owner wants a different end sound)
- Start: one short soft tick. Finish of recording: no sound (the pill says "Transcribing…").
  Text pasted: one soft two-note chime. Nothing heard: the existing low tone. A "Sounds" toggle in
  Settings **(my call)**.

### Language (owner)
- Settings picker: English / German. Passed to whisper (`-l en|de`) and to the clean-up prompt,
  which says to keep the language and never translate. UI stays English.

### Clean-up level (owner wants grammatically correct output; "grammar via shortcut" read as a
setting, not a third hotkey — **my call**)
- Off / Light (punctuation, fillers, self-corrections — today's behaviour) / Full (Light plus
  grammar, word order and obvious recognition errors). Default Full.

### Misspellings (owner)
- Settings section with two boxes (misspelled, correct) and Add; list with Delete.
- Stored in `~/.cache/mac-dictation/word_subs.json` (user file, outside the signed bundle),
  merged over the bundled defaults; user entries win. Applied before and after the clean-up so the
  model cannot undo them **(my call)**. Also fed to whisper as vocabulary (as today).

### Model provider (owner: Copilot like Amber; Claude and others with API keys)
- Picker: Local Ollama (default) / GitHub Copilot / Claude API / OpenAI API, each with a model
  field. Defaults: `gemma4`, `gpt-4.1`, `claude-opus-5-5`, `gpt-4.1` **(my call)**.
- Copilot: token from `gh auth token --hostname github.com` on every dictation, never stored by
  AUDAX; API host from `GET https://api.github.com/copilot_internal/user` (`endpoints.api`), host
  only cached 24 h; `POST {host}/chat/completions`. Sign-in is a button that opens Terminal with
  `gh auth login --hostname github.com --web`. **Copilot requires the GitHub CLI** at
  `/opt/homebrew/bin/gh` or `/usr/local/bin/gh`.
- Claude and OpenAI keys live in the macOS Keychain (service `local.audax`), entered in Settings,
  and are handed to the Python script on stdin — never in the environment or on disk.
- Claude is called over raw HTTP with the same built-in `urllib` as the other three providers:
  the script runs under Apple's `/usr/bin/python3` 3.9 inside a signed bundle with no package
  installs **(my call)**. Request per the current API reference: `anthropic-version: 2023-06-01`,
  `output_config.effort: low`, `fallbacks: "default"` with header
  `anthropic-beta: server-side-fallback-2026-07-01`.
- On any provider failure (offline, 401, timeout, model not offered) the raw transcript is
  pasted and the pill flashes "Pasted without clean-up"; the error is logged without secrets.
- The footer promise becomes conditional: local → "Audio and text never leave this Mac."; remote
  → "Audio stays on this Mac. Text is sent to <Provider> for clean-up."
- Open governance point, recorded not resolved: an internal app using a person's Copilot token
  has no written approval or prohibition (same note exists for Amber).
- "Claude Code CLI" as a provider: not built. Different auth, no clear benefit over the API key.

### Speed **(my call)**
- Keep gemma4 loaded with a keep-alive every 4 minutes while Ollama is the provider and clean-up
  is on (today it is only warmed when recording starts, which races the dictation).
- Read the whisper model file into the OS cache when recording starts (`cat` to `/dev/null`).
- Not built: a resident whisper server. Median STT is 0.8 s; revisit if the tail matters.

### Windows **(my call)**
- Main window: header, status checks, Try-it box, transcripts, footer with Settings… and Open log.
  Resizable. The old Settings box and the "pause" picker go.
- Settings window: Recording (two shortcut recorders, sounds, language), Clean-up (level,
  provider, model, key / sign-in), Words (misspelling table). Opened from the footer and the
  menu-bar menu.

### Script contract **(my call)**
- `dictate.py <wav>` reads one JSON object from stdin (`{provider, model, language, cleanup,
  api_key}`; missing keys default to local Ollama, `en`, `full`) and prints one JSON object
  `{"text": str, "cleanup": "ok"|"skipped"|"off", "error": str|null}`. Exit codes unchanged
  (0 text, 3 nothing heard, 1 error).

## Non-goals
- Auto language detection. A grammar-only hotkey. Streaming responses. Any change to setup.sh's
  Ollama install (local stays the default). Updating the architecture diagram (stale; noted).

## Constraints
- Python 3.9 syntax only (Apple's `/usr/bin/python3` is 3.9.6). No third-party packages.
- Swift compiled by `build.sh` with `swiftc -swift-version 5`; macOS 14+ (`MIN_MACOS="14.0"` pins
  the deployment target explicitly; swiftc's default was the SDK version, which this Mac cannot run).
- Carbon hot keys (no Accessibility needed for them); key release via `kEventHotKeyReleased`.
- Secrets never in `ps`-visible places: no argv, no environment, no log lines.
- Tests: `/usr/bin/python3 test_dictate.py` style (plain asserts), plus `test_providers.py`.
- The installed app `/Applications/AUDAX.app` is byte-identical to `dist/20261021-172024`
  (validated 23 Oct), so replacing it loses nothing; every build keeps its own DMG.
- The project had no git repository; one is initialised at the start of implementation (local,
  no remote). Rollback before that: `_backup-2026-10-23-before-v2/`.
