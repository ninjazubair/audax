# Changelog

All notable changes to AUDAX. Versions follow [Semantic Versioning](https://semver.org/); the
single source of the version is the `VERSION` file. Each release has a git tag `vX.Y.Z` and a
self-signed DMG attached to the GitHub release.

## [0.3.1] — 2026-10-24

### Added

- AUDAX is a regular Mac app: Dock icon, ⌘-Tab entry, standard AUDAX / Edit / Window menus,
  Dock menu (Start / stop dictation, Settings), Dock badge while recording (●) and
  transcribing (…). It keeps running when its window is closed; the menu-bar icon stays.
- Close Window (⌘W).
- About shows the version and build stamp. `VERSION` file is the single source of the version.

### Changed

- A dictation started while AUDAX is in front with no window open goes to the app you used last.
- The recording pill stays visible while AUDAX is hidden or in the background.
- Background checks (Ollama, GitHub CLI, Keychain) run only while an AUDAX window is visible;
  timers allow macOS to batch wake-ups.
- First-run setup now tells you to hold Fn and to set "Press 🌐 key to" to Do Nothing.

### Fixed

- The Fn key listener is recreated after Accessibility is re-granted only when no dictation is
  running, and starts with the current Fn state.

## [0.3.0] — 2026-10-24

### Added

- Fn shortcuts: hold **Fn** to talk, **Fn Space** to lock hands-free (set any Fn shortcut in
  Settings). Pressing another key while holding Fn cancels silently.
- Hint and button to set System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.
- GitHub Copilot model picker filled from your seat's model list; default `gpt-6.1-sol`
  (responses API supported).
- Resident speech server (whisper-server, beam search): speech recognition ≈0.15 s instead of
  ≈0.45 s, with automatic fallback to whisper-cli.
- Audible two-note start sound.

### Fixed

- The start sound is cut short when a Fn chord cancels the recording.
- Hardening of the Fn key listener after a system timeout; clean teardown.

## [0.2.1] — 2026-10-24

### Added

- "Remove key" for saved Claude / OpenAI API keys.

### Changed

- Shortcuts must include ⌃ or ⌥ (⇧-only and ⌘-only combinations would steal normal typing).
- A recording that hits the 5-minute limit is copied to the clipboard, never pasted.
- The word list re-reads your file before saving (hand edits are kept) and logs failed writes.

### Fixed

- A wedged audio output no longer crashes the app when a sound plays.

## [0.2.0] — 2026-10-23

### Added

- Hold-to-talk and a separate hands-free shortcut; silence detection removed.
- Settings window: record your own shortcuts, English / German, clean-up Off / Light / Full,
  your own word corrections (an unreadable word file is moved aside, never overwritten).
- Clean-up providers: local Ollama, GitHub Copilot (existing seat via the GitHub CLI), Claude
  API, OpenAI API (keys in the Keychain).
- "Pasted without clean-up" when a provider fails — the raw transcript is always pasted.
- Softer sounds, a silence floor, a resizable main window, model keep-alive.

## [0.1.0] — 2026-10-21

### Added

- First version: menu-bar dictation with ⌃⌥D, local whisper.cpp (large-v3-turbo) speech
  recognition, local Ollama clean-up, a transcript list with Copy, JSON-lines log.

[0.3.1]: https://github.com/zuhussai_adobe/audax/releases/tag/v0.3.1
[0.3.0]: https://github.com/zuhussai_adobe/audax/releases/tag/v0.3.0
[0.2.1]: https://github.com/zuhussai_adobe/audax/releases/tag/v0.2.1
[0.2.0]: https://github.com/zuhussai_adobe/audax/releases/tag/v0.2.0
[0.1.0]: https://github.com/zuhussai_adobe/audax/releases/tag/v0.1.0
